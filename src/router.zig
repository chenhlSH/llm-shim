//! 运行时路由/方言自愈 + 偶发问题内部消化 + 成功路径写回。
//!
//! 策略：
//! - 上游原生支持该入站方言（chat completions / anthropic / responses）就保持原生直发；
//!   不可用（404/405/非 JSON 等 PATH_MISMATCH 信号）则由该 provider 已验证的 primary
//!   方言映射（翻译）后提供给下游。
//! - 任何一次成功即固定该 provider 的成功路径与方言；首次固定/变化时原子写回
//!   providers.json（增量、重启可直接复用）。
//! - 偶发失败内部消化：5xx/网络按秒级退避重试（默认 2s/5s）；429 按 Retry-After
//!   （≤10s）等待重试一次；档位被拒自动"省略 → medium"降级重试，成功后记住该
//!   (provider, model) 的有效做法，后续第一次尝试就应用。
//! - 真消化不了（AUTH/CONTEXT_WINDOW/尝试耗尽）才把错误抛给上层。
const std = @import("std");
const types = @import("types.zig");
const providers_mod = @import("providers.zig");
const probe_mod = @import("probe.zig");
const env = @import("env.zig");
const clock = @import("clock.zig");
const openai_up = @import("upstream/openai.zig");
const anthropic_up = @import("upstream/anthropic.zig");
const responses_up = @import("upstream/responses.zig");
const watchdog_mod = @import("watchdog.zig");
const client_key = @import("client_key.zig");
const diag = @import("diag.zig");

pub const Dialect = types.Protocol;
pub const Failure = openai_up.Failure;

pub const Route = struct {
    base_url: []const u8,
    dialect: Dialect,
};

const dialect_count = 3;
const NativeState = enum { unknown, ok, bad };

const ProviderState = struct {
    /// 固定成功路径（null = 还没成功过）。
    base_url: ?[]const u8 = null,
    /// 已验证可用的翻译基准方言（null = 未知，退回 profile.protocol）。
    primary: ?Dialect = null,
    /// 按方言记录"是否可用"（三方言互备环的记忆）。
    native: [dialect_count]NativeState = .{ .unknown, .unknown, .unknown },
    /// 各方言被判"坏"的时间（负缓存 TTL 后自动再试一次，避免一次抖动永久改道）。
    native_bad_at_ms: [dialect_count]i64 = .{ 0, 0, 0 },
    /// 负缓存：最近一次发现失败的时间（TTL 内不再扫）。
    discovery_failed_at_ms: i64 = 0,
};

/// 某方言当前是否可用（bad 且未过 TTL 才算不可用）。
fn usableLocked(state: *const ProviderState, dialect: Dialect, now_ms: i64) bool {
    if (state.native[@backingInt(dialect)] != .bad) return true;
    return now_ms - state.native_bad_at_ms[@backingInt(dialect)] >= negative_ttl_ms;
}

/// 换方言候选顺序（"翻译距离"由近到远）：当前方言 → 另外两个。
/// openai 与 responses 同族（互译最短），anthropic 差异最大放最后。
fn fallbackOrder(current: Dialect) [2]Dialect {
    return switch (current) {
        .openai => .{ .responses, .anthropic },
        .responses => .{ .openai, .anthropic },
        .anthropic => .{ .openai, .responses },
    };
}

const EffortAdaptation = struct {
    omit: bool = false,
    effort: ?[]const u8 = null,
};

/// 退避/等待参数：AUTO_COMPAT_RETRY_DELAY_MS 是百分比缩放（默认 100；测试设 1 走快档）。
pub const retry_scale_env = "AUTO_COMPAT_RETRY_DELAY_MS";
pub const default_retry_scale: u64 = 100;
const first_transient_delay_ms: u64 = 2000;
const second_transient_delay_ms: u64 = 5000;
const rate_limit_default_wait_ms: u64 = 3000;
const rate_limit_max_wait_ms: u64 = 10_000;
const total_budget_ms: i64 = 20_000;
const negative_ttl_ms: i64 = 300_000;
const max_attempts: usize = 7;

/// 失败后的处置计划（decideFailure 纯函数的输出；callHealed 只负责执行与副作用）。
pub const Action = union(enum) {
    /// 切到 primary 方言重试（原生不可用 → 翻译）
    retry_dialect,
    /// 运行时发现路径/方言
    path_discovery,
    /// 省略档位重试
    omit_effort,
    /// 降 medium 重试
    medium_effort,
    /// 等 wait 毫秒后重试
    rate_limit: u64,
    /// 退避 wait 毫秒后重试
    transient: u64,
    /// 上抛
    give_up,
};

pub const Decision = struct {
    action: Action,
    /// PATH_MISMATCH 且本次是"原生尝试"且尚未回退过：先记"原生不可用"（即使没有回退目标）。
    mark_native_bad: bool = false,
};

pub const DecisionFlags = struct {
    tried_path_discovery: bool = false,
    tried_omit: bool = false,
    tried_medium: bool = false,
    transient_retries: usize = 0,
    rate_limit_retries: usize = 0,
    /// 本次请求还能换的方言数（未试过、且未被记忆为坏的其它方言；0 = 没得换）
    remaining_fallbacks: usize = 0,
    /// 本次是否获准换方言：首次换不设预算门槛；第二次换要求在总预算内（客户端耐心有限）
    fallback_allowed: bool = true,
    /// 负缓存允许再发现
    discovery_allowed: bool = true,
    within_budget: bool = true,
    scale: u64 = 100,
};

/// 失败分类 → 处置计划。纯函数（无 IO/无锁），边界由调用方通过 flags 提供。
pub fn decideFailure(failure: Failure, flags: DecisionFlags) Decision {
    if (std.mem.eql(u8, failure.code, "PATH_MISMATCH")) {
        // 这条方言的路由不存在（404/405/非 JSON）：记坏，并沿环试下一个方言
        if (dialectFallback(flags)) |fallback| return fallback;
        if (!flags.tried_path_discovery and flags.discovery_allowed) return .{ .action = .path_discovery, .mark_native_bad = true };
        return .{ .action = .give_up, .mark_native_bad = true };
    }
    if (std.mem.eql(u8, failure.code, "EFFORT_UNSUPPORTED")) {
        if (!flags.tried_omit) return .{ .action = .omit_effort };
        if (!flags.tried_medium) return .{ .action = .medium_effort };
        return .{ .action = .give_up };
    }
    if (std.mem.eql(u8, failure.code, "RATE_LIMIT")) {
        if (flags.rate_limit_retries < 1 and flags.within_budget) {
            return .{ .action = .{ .rate_limit = rateLimitWait(failure.retry_after_ms, flags.scale) } };
        }
        // 重试仍被限流：若还在"原生"方言上且有映射目标，把机会用在换方言（上游可能只是这条路由被限）。
        if (dialectFallback(flags)) |fallback| return fallback;
        return .{ .action = .give_up };
    }
    // TIMEOUT（含看门狗打断的阻塞读）：与 5xx 同档，退避重试；重试耗尽后换方言兜底。
    if (std.mem.eql(u8, failure.code, "TIMEOUT") or failure.status >= 500 or std.mem.eql(u8, failure.code, "SERVER")) {
        if (flags.transient_retries < 2 and flags.within_budget) {
            return .{ .action = .{ .transient = transientDelay(flags.transient_retries, flags.scale) } };
        }
        // 同一条路由反复 5xx/TIMEOUT（真机案例：厂商 /responses 坏而 /chat/completions 正常）：
        // 重试已证明无用，改用上游 primary 方言做翻译（网关存在的意义）；只此一次。
        if (dialectFallback(flags)) |fallback| return fallback;
        return .{ .action = .give_up };
    }
    // AUTH / CONTEXT_WINDOW_EXCEEDED / 其他 INVALID_REQUEST：真错误，直接上抛
    return .{ .action = .give_up };
}

/// 换方言兜底（纯函数判定）：环上还有没试过的方言、且本次获准换 → 切过去做翻译重试。
/// "三个方言互备"：任何一条反复失败（5xx/429/超时/404）都沿环试下一条，最多换两次（三条都试到）。
fn dialectFallback(flags: DecisionFlags) ?Decision {
    if (flags.remaining_fallbacks == 0) return null;
    if (!flags.fallback_allowed) return null;
    return .{ .action = .retry_dialect, .mark_native_bad = true };
}

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    discovery_mutex: std.Io.Mutex = .init,
    persist_mutex: std.Io.Mutex = .init,
    providers: std.StringHashMapUnmanaged(ProviderState) = .empty,
    efforts: std.StringHashMapUnmanaged(EffortAdaptation) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.providers.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.base_url) |base| self.allocator.free(base);
        }
        self.providers.deinit(self.allocator);
        var effort_iterator = self.efforts.iterator();
        while (effort_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.effort) |value| self.allocator.free(value);
        }
        self.efforts.deinit(self.allocator);
    }

    /// 调用方必须已持有 mutex（本函数由其它带锁方法内部调用）。
    fn stateForLocked(self: *Cache, name: []const u8) !*ProviderState {
        if (self.providers.getPtr(name)) |state| return state;
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.providers.put(self.allocator, key, .{});
        return self.providers.getPtr(key).?;
    }

    /// 本次生效路由：原生可用/未知 → 入站方言（原生优先）；原生不可用 → primary（映射）。
    pub fn effectiveRoute(self: *Cache, profile: *const providers_mod.Profile, inbound: Dialect) Route {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.providers.getPtr(profile.name);
        const base = if (state) |s| (s.base_url orelse profile.base_url) else profile.base_url;
        const primary = if (state) |s| (s.primary orelse profile.protocol) else profile.protocol;
        var dialect = inbound;
        if (state) |s| {
            const now_ms = clock.unixMilli();
            if (!usableLocked(s, inbound, now_ms)) {
                dialect = if (usableLocked(s, primary, now_ms)) primary else blk: {
                    for (fallbackOrder(inbound)) |candidate| {
                        if (candidate == primary) continue;
                        if (usableLocked(s, candidate, now_ms)) break :blk candidate;
                    }
                    break :blk primary; // 全坏：仍试 primary（记忆不阻塞尝试，只是排序）
                };
            }
        }
        return .{ .base_url = base, .dialect = dialect };
    }

    pub fn primaryFor(self: *Cache, profile: *const providers_mod.Profile) Dialect {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.providers.getPtr(profile.name);
        return if (state) |s| (s.primary orelse profile.protocol) else profile.protocol;
    }

    pub fn fixedRoute(self: *Cache, profile: *const providers_mod.Profile) ?Route {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.providers.getPtr(profile.name) orelse return null;
        const base = state.base_url orelse return null;
        return .{ .base_url = base, .dialect = state.primary orelse profile.protocol };
    }

    /// 固定成功路径/方言（发现命中或 prewarm）；返回"路由字段是否变化"（变化才需要写回）。
    pub fn fixRoute(self: *Cache, profile: *const providers_mod.Profile, base: []const u8, primary: ?Dialect) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = try self.stateForLocked(profile.name);
        var changed = false;
        if (state.base_url == null or !std.mem.eql(u8, state.base_url.?, base)) {
            if (state.base_url) |old| self.allocator.free(old);
            state.base_url = try self.allocator.dupe(u8, base);
            changed = true;
        }
        if (state.primary == null) {
            if (primary) |value| {
                state.primary = value;
                changed = true;
            }
        }
        // 刚探通的方言标为可用（清掉可能存在的"坏"记忆：此前的失败可能是旧路径，不是这个方言）
        if (primary) |value| {
            state.native[@backingInt(value)] = .ok;
            state.native_bad_at_ms[@backingInt(value)] = 0;
        }
        return changed;
    }

    /// 成功一次即固定：记录本次成功的 base/方言，并把这条方言标为可用（清掉"坏"记忆）。
    pub fn recordSuccess(self: *Cache, profile: *const providers_mod.Profile, base: []const u8, dialect: Dialect) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = try self.stateForLocked(profile.name);
        var route_changed = false;
        if (state.base_url == null or !std.mem.eql(u8, state.base_url.?, base)) {
            if (state.base_url) |old| self.allocator.free(old);
            state.base_url = try self.allocator.dupe(u8, base);
            route_changed = true;
        }
        if (state.primary == null) {
            state.primary = dialect;
            route_changed = true;
        }
        state.native[@backingInt(dialect)] = .ok;
        state.native_bad_at_ms[@backingInt(dialect)] = 0;
        return route_changed;
    }

    pub fn markNative(self: *Cache, name: []const u8, dialect: Dialect, value: NativeState) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = try self.stateForLocked(name);
        state.native[@backingInt(dialect)] = value;
        state.native_bad_at_ms[@backingInt(dialect)] = if (value == .bad) clock.unixMilli() else 0;
    }

    /// 某方言当前是否可用（bad 且未过负缓存 TTL 才算不可用）。
    pub fn dialectUsable(self: *Cache, name: []const u8, dialect: Dialect) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.providers.getPtr(name) orelse return true;
        return usableLocked(state, dialect, clock.unixMilli());
    }

    /// 三方言互备环的候选（顺序：primary 优先，其余按翻译距离）；已试过/记忆为坏的跳过。
    /// 返回候选个数（≤2），写入 out。
    pub fn fallbackCandidates(
        self: *Cache,
        profile: *const providers_mod.Profile,
        current: Dialect,
        tried: [dialect_count]bool,
        out: *[2]Dialect,
    ) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ms = clock.unixMilli();
        const state = self.providers.getPtr(profile.name);
        const primary = if (state) |s| (s.primary orelse profile.protocol) else profile.protocol;
        var ordered: [2]Dialect = undefined;
        var ordered_len: usize = 0;
        if (primary != current and !tried[@backingInt(primary)]) {
            ordered[ordered_len] = primary;
            ordered_len += 1;
        }
        for (fallbackOrder(current)) |candidate| {
            if (candidate == current or candidate == primary) continue;
            if (tried[@backingInt(candidate)]) continue;
            ordered[ordered_len] = candidate;
            ordered_len += 1;
        }
        var count: usize = 0;
        for (ordered[0..ordered_len]) |dialect| {
            if (state) |s| {
                if (!usableLocked(s, dialect, now_ms)) continue;
            }
            out[count] = dialect;
            count += 1;
        }
        return count;
    }

    pub fn canDiscover(self: *Cache, name: []const u8, now_ms: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.providers.getPtr(name) orelse return true;
        if (state.discovery_failed_at_ms == 0) return true;
        return now_ms - state.discovery_failed_at_ms >= negative_ttl_ms;
    }

    pub fn noteDiscoveryFailure(self: *Cache, name: []const u8, now_ms: i64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = try self.stateForLocked(name);
        state.discovery_failed_at_ms = now_ms;
    }

    pub fn effortFor(self: *Cache, key: []const u8) ?EffortAdaptation {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.efforts.get(key);
    }

    pub fn recordEffortAdaptation(self: *Cache, key: []const u8, adaptation: EffortAdaptation) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.efforts.getPtr(key)) |existing| {
            if (existing.effort) |old| self.allocator.free(old);
            existing.* = adaptation;
            if (adaptation.effort) |value| existing.effort = try self.allocator.dupe(u8, value);
            return;
        }
        var owned = adaptation;
        if (adaptation.effort) |value| owned.effort = try self.allocator.dupe(u8, value);
        try self.efforts.put(self.allocator, try self.allocator.dupe(u8, key), owned);
    }
};

/// 统一上游入口：按生效方言选上游模块（profile 的 base_url 已由调用方覆盖为固定路径）。
fn callUpstream(
    arena: std.mem.Allocator,
    io: std.Io,
    profile: *const providers_mod.Profile,
    dialect: Dialect,
    request: types.GenerateRequest,
    failure_out: *?Failure,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), types.Chunk) anyerror!void,
) !void {
    switch (dialect) {
        .openai => try openai_up.callStreaming(arena, io, profile, request, failure_out, ctx, on_chunk),
        .anthropic => try anthropic_up.callStreaming(arena, io, profile, request, failure_out, ctx, on_chunk),
        .responses => try responses_up.callStreaming(arena, io, profile, request, failure_out, ctx, on_chunk),
    }
}

/// 带回环自愈的上游调用：
/// - 原生优先；PATH_MISMATCH 时"记原生不可用 → 映射到 primary"或"运行时发现（后缀+方言）"；
/// - EFFORT_UNSUPPORTED 时"省略 → medium"重试并记住；
/// - 5xx/网络退避重试（2s/5s，可缩放）；429 按 Retry-After 等待一次；
/// - frames_sent 为真（已向客户端写出 SSE 帧）时绝不重试，直接上抛。
pub fn callHealed(
    arena: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,
    profile: *const providers_mod.Profile,
    inbound: Dialect,
    request: types.GenerateRequest,
    failure_out: *?Failure,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), types.Chunk) anyerror!void,
    frames_sent: ?*const bool,
) !Dialect {
    // 入口归一：messages 里的 system 块 → request.system（三个上游都只读 request.system）
    var req = try types.extractSystem(arena, request);
    var attempts: usize = 0;
    const started_ms = clock.unixMilli();
    const scale = retryScale();
    var route = cache.effectiveRoute(profile, inbound);

    // 档位记忆：成功过的做法第一次尝试就应用，省掉往返
    const effort_key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ profile.name, req.model });
    if (cache.effortFor(effort_key)) |remembered| {
        if (remembered.omit) {
            req.reasoning_effort = null;
        } else if (remembered.effort) |value| {
            if (types.Effort.parse(value)) |effort| req.reasoning_effort = effort;
        }
    }

    var first_failure: ?Failure = null;
    var last_failure: ?Failure = null;
    // 最近一次"有信息量"的失败（非 PATH_MISMATCH）：换方言时后试的方言可能只是没有这条路由，
    // 那不是客户端的真实问题（真问题是 TIMEOUT/5xx/429）。
    var last_meaningful_failure: ?Failure = null;
    var tried_dialects: [dialect_count]bool = .{ false, false, false };
    tried_dialects[@backingInt(route.dialect)] = true;
    var dialect_switches: usize = 0;
    var tried_path_discovery = false;
    var tried_omit = false;
    var tried_medium = false;
    var transient_retries: usize = 0;
    var rate_limit_retries: usize = 0;

    while (attempts < max_attempts) {
        attempts += 1;
        failure_out.* = null;
        var attempt_profile = profile.*;
        attempt_profile.base_url = route.base_url;
        const attempt_started_ms = clock.unixMilli();
        diag.print("attempt {d}/{d} {s} {s}\n", .{ attempts, max_attempts, @tagName(route.dialect), route.base_url });
        callUpstream(arena, io, &attempt_profile, route.dialect, req, failure_out, ctx, on_chunk) catch |err| {
            if (frames_sent) |flag| {
                if (flag.*) {
                    // 已向客户端出帧：不可重试；仍留一行汇总（这是最常见的"turn 失败但日志没结论"来源）
                    logCallSummary(profile, req.model, inbound, route.dialect, attempts, dialect_switches, started_ms, .{
                        .status = 502,
                        .code = "MID_STREAM",
                        .message = @errorName(err),
                        .retry_after_ms = null,
                    });
                    return err;
                }
            }
            const failure = failure_out.* orelse synthesizeTransportFailure(err);
            failure_out.* = failure;
            var failure_snippet_buffer: [160]u8 = undefined;
            diag.print("attempt {d} {s} FAILED http={d} code={s} {d}ms msg={s}\n", .{
                attempts,
                @tagName(route.dialect),
                failure.status,
                failure.code,
                clock.unixMilli() - attempt_started_ms,
                diag.snippet(&failure_snippet_buffer, failure.message, 160),
            });
            if (first_failure == null) first_failure = failure;
            last_failure = failure;
            if (!std.mem.eql(u8, failure.code, "PATH_MISMATCH")) last_meaningful_failure = failure;

            const in_budget = withinBudget(started_ms);
            var candidates: [2]Dialect = undefined;
            const candidate_count = cache.fallbackCandidates(profile, route.dialect, tried_dialects, &candidates);
            const decision = decideFailure(failure, .{
                .tried_path_discovery = tried_path_discovery,
                .tried_omit = tried_omit,
                .tried_medium = tried_medium,
                .transient_retries = transient_retries,
                .rate_limit_retries = rate_limit_retries,
                .remaining_fallbacks = candidate_count,
                .fallback_allowed = dialect_switches == 0 or in_budget,
                .discovery_allowed = cache.canDiscover(profile.name, clock.unixMilli()),
                .within_budget = in_budget,
                .scale = scale,
            });
            // 刚失败的这条方言记坏（带 TTL）；成功一次会清掉。
            if (decision.mark_native_bad) try cache.markNative(profile.name, route.dialect, .bad);

            switch (decision.action) {
                .retry_dialect => {
                    // 决策前刚记完"坏"，候选已排除刚失败的这条方言；重新取一次拿首选。
                    var picks: [2]Dialect = undefined;
                    const pick_count = cache.fallbackCandidates(profile, route.dialect, tried_dialects, &picks);
                    if (pick_count == 0) {
                        // 与决策不一致的兜底（理论不可达）
                        failure_out.* = last_meaningful_failure orelse failure;
                        logCallSummary(profile, req.model, inbound, route.dialect, attempts, dialect_switches, started_ms, failure_out.*);
                        return error.UpstreamFailure;
                    }
                    const from_dialect = route.dialect;
                    const after_retries = transient_retries > 0 or rate_limit_retries > 0;
                    tried_dialects[@backingInt(from_dialect)] = true;
                    dialect_switches += 1;
                    transient_retries = 0;
                    rate_limit_retries = 0;
                    route.dialect = picks[0];
                    // 404 类 = 这条路由不存在；5xx/超时 = 这条方言失败；预算已耗尽则不再重试直接换。
                    const reason: []const u8 = if (std.mem.eql(u8, failure.code, "PATH_MISMATCH")) "unavailable" else "failed";
                    const detail: []const u8 = if (after_retries) " after retries" else if (!in_budget) " (budget spent)" else "";
                    diag.print("{s}: {s} {s}{s} (last HTTP {d} {s}), mapping via {s} ({d}/3 dialects tried)\n", .{
                        profile.name, @tagName(from_dialect), reason, detail, failure.status, failure.code, @tagName(route.dialect), dialect_switches + 1,
                    });
                    continue;
                },
                .path_discovery => {
                    tried_path_discovery = true;
                    if (try discoverRuntime(arena, io, cache, profile, req.model, route)) |found| {
                        route = found;
                        continue;
                    }
                    try cache.noteDiscoveryFailure(profile.name, clock.unixMilli());
                    // 发现也失败：报告"有信息量"的失败（别把回退探测的 404 当成客户端的真实问题）
                    failure_out.* = last_meaningful_failure orelse failure;
                    logCallSummary(profile, req.model, inbound, route.dialect, attempts, dialect_switches, started_ms, failure_out.*);
                    return error.UpstreamFailure;
                },
                .omit_effort => {
                    tried_omit = true;
                    req.reasoning_effort = null;
                    diag.print("{s}/{s}: effort rejected by upstream, retrying without effort\n", .{ profile.name, req.model });
                    continue;
                },
                .medium_effort => {
                    tried_medium = true;
                    req.reasoning_effort = .medium;
                    diag.print("{s}/{s}: effort rejected again, retrying with medium\n", .{ profile.name, req.model });
                    continue;
                },
                .rate_limit => |wait| {
                    rate_limit_retries += 1;
                    diag.print("{s}: upstream rate-limited, waiting {d}ms before retry\n", .{ profile.name, wait });
                    clock.sleepMilli(wait);
                    continue;
                },
                .transient => |wait| {
                    transient_retries += 1;
                    diag.print("{s}: transient upstream failure (HTTP {d}), retrying in {d}ms\n", .{ profile.name, failure.status, wait });
                    clock.sleepMilli(wait);
                    continue;
                },
                .give_up => {
                    failure_out.* = last_meaningful_failure orelse failure;
                    logCallSummary(profile, req.model, inbound, route.dialect, attempts, dialect_switches, started_ms, failure_out.*);
                    return error.UpstreamFailure;
                },
            }
        };

        diag.print("attempt {d} {s} ok {d}ms\n", .{ attempts, @tagName(route.dialect), clock.unixMilli() - attempt_started_ms });
        // 成功一次即固定 + 写回；必要时记住档位适配
        const route_changed = try cache.recordSuccess(profile, route.base_url, route.dialect);
        if (route_changed) persistRoute(io, cache, profile, route.base_url, route.dialect);
        if (tried_omit and req.reasoning_effort == null) {
            try cache.recordEffortAdaptation(effort_key, .{ .omit = true });
        } else if (tried_medium) {
            try cache.recordEffortAdaptation(effort_key, .{ .effort = "medium" });
        }
        logCallSummary(profile, req.model, inbound, route.dialect, attempts, dialect_switches, started_ms, null);
        return route.dialect;
    }

    failure_out.* = last_meaningful_failure orelse first_failure orelse last_failure;
    logCallSummary(profile, req.model, inbound, route.dialect, attempts, dialect_switches, started_ms, failure_out.*);
    return error.UpstreamFailure;
}

/// 单请求汇总（成功/失败各一行）：让客户端的一次失败能与网关日志一一对应。
/// 形状：`intern-ai/glm-5.3: responses->anthropic FAILED code=SERVER attempts=2 switches=1 40211ms`。
fn logCallSummary(
    profile: *const providers_mod.Profile,
    model: []const u8,
    inbound: Dialect,
    final_dialect: Dialect,
    attempts: usize,
    switches: usize,
    started_ms: i64,
    failure: ?Failure,
) void {
    const elapsed = clock.unixMilli() - started_ms;
    if (failure) |value| {
        var summary_buffer: [160]u8 = undefined;
        diag.print("{s}/{s}: {s}->{s} FAILED code={s} attempts={d} switches={d} {d}ms msg={s}\n", .{
            profile.name,
            model,
            @tagName(inbound),
            @tagName(final_dialect),
            value.code,
            attempts,
            switches,
            elapsed,
            diag.snippet(&summary_buffer, value.message, 160),
        });
    } else {
        diag.print("{s}/{s}: {s}->{s} OK attempts={d} switches={d} {d}ms\n", .{
            profile.name, model, @tagName(inbound), @tagName(final_dialect), attempts, switches, elapsed,
        });
    }
}

/// 传输层失败的兜底分类：没有上游 HTTP 响应体时的错误。
/// 看门狗按空闲超时 `shutdown()` 上游 socket 后，阻塞读会以连接中断类错误返回——
/// 与"对端真的断开"同类，都按 TIMEOUT 归类（可重试；真错误仍由 HTTP 状态码分类）。
fn synthesizeTransportFailure(err: anyerror) Failure {
    // 看门狗已判定空闲超时：无论底层错误叫什么（std 常抛 HttpConnectionClosing），
    // 都归 TIMEOUT（可重试）——这正是"慢/黑洞上游有界失败"的语义。
    if (watchdog_mod.upstreamTimedOut()) {
        return .{ .status = 504, .code = "TIMEOUT", .message = "upstream idle timeout (watchdog interrupted the blocked read)" };
    }
    // Zig 的 std.http 把上游 TLS 握手/证书校验的**所有**失败折叠成 TlsInitializationFailed
    // （证书过期/未生效、主机名不匹配、CA 缺失、握手失败……都叫这个）。给客户端一个能行动的说明。
    if (err == error.TlsInitializationFailed) {
        diag.print("upstream TLS handshake failed (certificate/CA/system clock, or the endpoint served a bad certificate); check `date` and the CA store\n", .{});
        return .{
            .status = 502,
            .code = "SERVER",
            .message = "upstream TLS handshake failed (certificate verification / CA / system clock, or the endpoint served an invalid certificate); check the gateway host's time and CA store, then retry",
        };
    }
    return switch (err) {
        error.ConnectionResetByPeer, error.SocketUnconnected, error.ConnectionTimedOut => .{
            .status = 504,
            .code = "TIMEOUT",
            .message = @errorName(err),
        },
        else => .{ .status = 502, .code = "SERVER", .message = @errorName(err) },
    };
}

/// 运行时紧凑发现：按 URL 形状增/减后缀找路径 + 用请求模型闭环 ping 方言。
/// 命中即固定并写回；无进展则返回 null（外层抛原错误 + 负缓存）。
fn discoverRuntime(
    arena: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,
    profile: *const providers_mod.Profile,
    model: []const u8,
    current: Route,
) !?Route {
    cache.discovery_mutex.lockUncancelable(cache.io);
    defer cache.discovery_mutex.unlock(cache.io);

    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    // 运行时发现同样使用"环境变量优先、其次入站 key"的解析结果（key 中转时发现才走得通）
    const key = client_key.resolve(profile.api_key_env).key;
    const base = (probe_mod.resolveApiBaseWith(arena, &client, current.base_url, key, .{ .quick = true }) catch null) orelse return null;
    var dialect: ?Dialect = null;
    if (probe_mod.probeProtocol(arena, &client, base, key, model) catch null) |detected| {
        dialect = @fromBackingInt(@intCast(@backingInt(detected)));
    }
    const resolved_dialect = dialect orelse current.dialect;
    if (std.mem.eql(u8, base, current.base_url) and resolved_dialect == current.dialect) return null; // 无进展

    const changed = try cache.fixRoute(profile, base, dialect);
    if (changed) persistRoute(io, cache, profile, base, dialect orelse profile.protocol);
    diag.print("{s}: route discovered {s} ({s})\n", .{ profile.name, base, @tagName(resolved_dialect) });
    return .{ .base_url = try arena.dupe(u8, base), .dialect = resolved_dialect };
}

/// 启动预热（后台线程）：只处理"装载期没能解析成功"的 provider，做一次紧凑发现；
/// 失败记负缓存，避免每个请求都重扫。成功即固定 + 写回。
pub fn prewarm(cache: *Cache, registry: *providers_mod.Registry, io: std.Io) void {
    for (registry.profiles.items) |*profile| {
        // 装载期已探测成功或带静态目录的内置剖面：跳过（首次真实请求成功时也会固定/写回）
        if (profile.detected or profile.models.len > 0) continue;
        if (cache.fixedRoute(profile) != null) continue;

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
        defer client.deinit();
        const key = env.get(profile.api_key_env) orelse "";

        const base = (probe_mod.resolveApiBaseWith(arena, &client, profile.base_url, key, .{ .quick = true }) catch null) orelse {
            cache.noteDiscoveryFailure(profile.name, clock.unixMilli()) catch {};
            clock.sleepMilli(prewarmGapMs());
            continue;
        };
        var primary: ?Dialect = null;
        if (probe_mod.detectModels(arena, &client, base, key) catch null) |models| {
            if (models.len > 0) {
                if (probe_mod.probeProtocol(arena, &client, base, key, models[0].id) catch null) |detected| {
                    primary = @fromBackingInt(@intCast(@backingInt(detected)));
                }
            }
        }
        const changed = cache.fixRoute(profile, base, primary) catch false;
        if (changed) {
            persistRoute(io, cache, profile, base, primary orelse profile.protocol);
        } else {
            diag.print("prewarm: {s} -> {s}\n", .{ profile.name, base });
        }
        clock.sleepMilli(prewarmGapMs());
    }
}

/// 成功路径原子写回 providers.json（同名覆盖；保留既有条目其它字段）。
fn persistRoute(
    io: std.Io,
    cache: *Cache,
    profile: *const providers_mod.Profile,
    base: []const u8,
    primary: Dialect,
) void {
    cache.persist_mutex.lockUncancelable(cache.io);
    defer cache.persist_mutex.unlock(cache.io);
    const path = env.getOr("AUTO_COMPAT_PROVIDERS_FILE", "providers.json");
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch null;
    const entries = [_]providers_mod.ProviderEntry{.{
        .name = profile.name,
        .base_url = base,
        .api_key_env = profile.api_key_env,
        .protocol = primary,
    }};
    const text = providers_mod.upsertProviders(arena, existing, &entries) catch |err| {
        diag.print("providers.json merge failed ({s}), skipping write-back\n", .{@errorName(err)});
        return;
    };
    providers_mod.writeTextAtomic(io, path, text) catch |err| {
        diag.print("providers.json write failed ({s}), skipping write-back\n", .{@errorName(err)});
        return;
    };
    diag.print("route fixed: {s} -> {s} ({s}), written to {s}\n", .{ profile.name, base, @tagName(primary), path });
}

fn prewarmGapMs() u64 {
    const scale = retryScale();
    if (scale >= 100) return 300;
    return 30; // 测试快档
}

fn retryScale() u64 {
    const raw = env.get(retry_scale_env) orelse return default_retry_scale;
    const parsed = std.fmt.parseInt(u64, raw, 10) catch return default_retry_scale;
    return if (parsed == 0) 1 else parsed;
}

fn withinBudget(started_ms: i64) bool {
    return clock.unixMilli() - started_ms < total_budget_ms;
}

fn transientDelay(retry_index: usize, scale: u64) u64 {
    const base = if (retry_index == 0) first_transient_delay_ms else second_transient_delay_ms;
    return base * scale / 100;
}

fn rateLimitWait(retry_after_ms: ?u64, scale: u64) u64 {
    if (retry_after_ms) |ms| return @min(ms, rate_limit_max_wait_ms);
    return rate_limit_default_wait_ms * scale / 100;
}

test "Cache: 原生优先 → 不可用则映射 primary，成功即固定" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = Cache.init(arena_state.allocator(), std.testing.io);

    const profile = providers_mod.Profile{
        .name = "p1",
        .display_name = "P1",
        .base_url = "https://p1.example/v1",
        .api_key_env = "K",
        .protocol = .openai,
        .models = &.{},
    };

    // 初始：原生未知 → 入站方言直发
    try std.testing.expectEqual(Dialect.anthropic, cache.effectiveRoute(&profile, .anthropic).dialect);
    try std.testing.expectEqualStrings("https://p1.example/v1", cache.effectiveRoute(&profile, .anthropic).base_url);

    // 原生不可用 → 映射到 primary
    try cache.markNative("p1", .anthropic, .bad);
    try std.testing.expectEqual(Dialect.openai, cache.effectiveRoute(&profile, .anthropic).dialect);

    // 发现到新路径 → 固定
    const changed = try cache.fixRoute(&profile, "https://p1.example/api/v1", .anthropic);
    try std.testing.expect(changed);
    const route = cache.effectiveRoute(&profile, .anthropic);
    try std.testing.expectEqualStrings("https://p1.example/api/v1", route.base_url);
    try std.testing.expectEqual(Dialect.anthropic, route.dialect);
    // primary 已固定为 anthropic，native[anthropic] 仍为 bad → 仍映射到 primary（同值）
    try std.testing.expectEqual(Dialect.anthropic, cache.primaryFor(&profile));

    // 成功记录：再次 fixRoute 同值不再算变化
    try std.testing.expect(!(try cache.fixRoute(&profile, "https://p1.example/api/v1", null)));
}

test "Cache: 三方言互备环（坏记忆 → 环上排序；TTL 后自动再试）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = Cache.init(arena_state.allocator(), std.testing.io);

    const profile = providers_mod.Profile{
        .name = "ring",
        .display_name = "Ring",
        .base_url = "https://ring.example/v1",
        .api_key_env = "K",
        .protocol = .openai,
        .models = &.{},
    };

    // 入站 responses 坏 → primary（openai）
    try cache.markNative("ring", .responses, .bad);
    try std.testing.expectEqual(Dialect.openai, cache.effectiveRoute(&profile, .responses).dialect);
    // openai 也坏 → 环上下一个（anthropic）
    try cache.markNative("ring", .openai, .bad);
    try std.testing.expectEqual(Dialect.anthropic, cache.effectiveRoute(&profile, .responses).dialect);

    // 候选列表：当前 openai、primary=openai（跳过）、responses 坏（过滤）→ 只剩 anthropic
    var tried: [dialect_count]bool = .{ false, false, false };
    tried[@backingInt(Dialect.openai)] = true;
    var out: [2]Dialect = undefined;
    try std.testing.expectEqual(@as(usize, 1), cache.fallbackCandidates(&profile, .openai, tried, &out));
    try std.testing.expectEqual(Dialect.anthropic, out[0]);

    // 已试过的方言不再候选
    tried[@backingInt(Dialect.anthropic)] = true;
    var out2: [2]Dialect = undefined;
    try std.testing.expectEqual(@as(usize, 0), cache.fallbackCandidates(&profile, .openai, tried, &out2));

    // 全坏：候选 0；effectiveRoute 仍给 primary 一次机会（记忆只排序、不阻塞尝试）
    try cache.markNative("ring", .anthropic, .bad);
    try std.testing.expectEqual(Dialect.openai, cache.effectiveRoute(&profile, .anthropic).dialect);

    // TTL：坏标记过期后视为可用（自动再试一次，避免一次抖动永久改道）
    var state = ProviderState{};
    state.native[@backingInt(Dialect.responses)] = .bad;
    state.native_bad_at_ms[@backingInt(Dialect.responses)] = 1_000;
    try std.testing.expect(!usableLocked(&state, .responses, 1_000 + negative_ttl_ms - 1));
    try std.testing.expect(usableLocked(&state, .responses, 1_000 + negative_ttl_ms));

    // 成功一次即清坏记忆
    try cache.markNative("ring", .responses, .ok);
    try std.testing.expect(cache.dialectUsable("ring", .responses));
}

test "Cache: 档位适配记忆与负缓存 TTL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = Cache.init(arena_state.allocator(), std.testing.io);

    try std.testing.expect(cache.effortFor("p/m") == null);
    try cache.recordEffortAdaptation("p/m", .{ .omit = true });
    try std.testing.expect(cache.effortFor("p/m").?.omit);
    try cache.recordEffortAdaptation("p/m", .{ .effort = "medium" });
    const adaptation = cache.effortFor("p/m").?;
    try std.testing.expect(!adaptation.omit);
    try std.testing.expectEqualStrings("medium", adaptation.effort.?);

    try std.testing.expect(cache.canDiscover("p", 1_000));
    try cache.noteDiscoveryFailure("p", 1_000);
    try std.testing.expect(!cache.canDiscover("p", 1_000 + 60_000)); // TTL 内不重扫
    try std.testing.expect(cache.canDiscover("p", 1_000 + 300_001)); // TTL 后恢复
}

test "退避参数：缩放与 Retry-After 上限" {
    try std.testing.expectEqual(@as(u64, 2000), transientDelay(0, 100));
    try std.testing.expectEqual(@as(u64, 5000), transientDelay(1, 100));
    try std.testing.expectEqual(@as(u64, 20), transientDelay(0, 1));
    try std.testing.expectEqual(@as(u64, 50), transientDelay(1, 1));
    try std.testing.expectEqual(@as(u64, 3000), rateLimitWait(null, 100));
    try std.testing.expectEqual(@as(u64, 2500), rateLimitWait(2500, 100));
    try std.testing.expectEqual(@as(u64, 10_000), rateLimitWait(60_000, 100));
}

test "decideFailure: PATH_MISMATCH 沿环换方言 → 发现 → 上抛" {
    const mismatch = Failure{ .status = 404, .code = "PATH_MISMATCH", .message = "404 page not found", .retry_after_ms = null };
    // 环上还有候选 → 换方言并记"这条方言坏"
    const first = decideFailure(mismatch, .{ .remaining_fallbacks = 2 });
    try std.testing.expectEqual(Action.retry_dialect, std.meta.activeTag(first.action));
    try std.testing.expect(first.mark_native_bad);

    // 环上试完（无候选）→ 走发现（仍记坏）
    const second = decideFailure(mismatch, .{ .remaining_fallbacks = 0 });
    try std.testing.expectEqual(Action.path_discovery, std.meta.activeTag(second.action));
    try std.testing.expect(second.mark_native_bad);

    // 发现已用过 / 负缓存未过期 → 上抛
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(mismatch, .{ .tried_path_discovery = true }).action));
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(mismatch, .{ .discovery_allowed = false }).action));

    // 第二次换方言要预算（fallback_allowed=false）→ 不再换，转发现
    try std.testing.expectEqual(Action.path_discovery, std.meta.activeTag(decideFailure(mismatch, .{ .remaining_fallbacks = 1, .fallback_allowed = false }).action));
}

test "decideFailure: 档位被拒 省略 → medium → 上抛" {
    const rejected = Failure{ .status = 400, .code = "EFFORT_UNSUPPORTED", .message = "该模型始终思考", .retry_after_ms = null };
    try std.testing.expectEqual(Action.omit_effort, std.meta.activeTag(decideFailure(rejected, .{}).action));
    try std.testing.expectEqual(Action.medium_effort, std.meta.activeTag(decideFailure(rejected, .{ .tried_omit = true }).action));
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(rejected, .{ .tried_omit = true, .tried_medium = true }).action));
}

test "decideFailure: 429/5xx 的等待值与次数/预算上限" {
    const limited = Failure{ .status = 429, .code = "RATE_LIMIT", .message = "", .retry_after_ms = 2500 };
    try std.testing.expectEqual(@as(u64, 2500), decideFailure(limited, .{}).action.rate_limit);
    // 无 Retry-After → 默认 3000 * scale/100
    const no_header = Failure{ .status = 429, .code = "RATE_LIMIT", .message = "", .retry_after_ms = null };
    try std.testing.expectEqual(@as(u64, 30), decideFailure(no_header, .{ .scale = 1 }).action.rate_limit);
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(limited, .{ .rate_limit_retries = 1 }).action));
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(limited, .{ .within_budget = false }).action));

    const server = Failure{ .status = 503, .code = "SERVER", .message = "busy", .retry_after_ms = null };
    try std.testing.expectEqual(@as(u64, 2000), decideFailure(server, .{}).action.transient);
    try std.testing.expectEqual(@as(u64, 5000), decideFailure(server, .{ .transient_retries = 1 }).action.transient);
    try std.testing.expectEqual(@as(u64, 20), decideFailure(server, .{ .scale = 1 }).action.transient);
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(server, .{ .transient_retries = 2 }).action));
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(server, .{ .within_budget = false }).action));
}

test "decideFailure: 5xx/429/TIMEOUT 重试耗尽后沿环换方言（三个方言互备，最多换两次）" {
    const server = Failure{ .status = 502, .code = "SERVER", .message = "busy", .retry_after_ms = null };
    const timeout = Failure{ .status = 504, .code = "TIMEOUT", .message = "", .retry_after_ms = null };
    const limited = Failure{ .status = 429, .code = "RATE_LIMIT", .message = "", .retry_after_ms = null };
    // 任何一条方言重试耗尽、环上还有候选 → 换下一个
    for ([_]Failure{ server, timeout, limited }) |failure| {
        const decision = decideFailure(failure, .{
            .transient_retries = 2,
            .rate_limit_retries = 1,
            .remaining_fallbacks = 2,
        });
        try std.testing.expectEqual(Action.retry_dialect, std.meta.activeTag(decision.action));
        try std.testing.expect(decision.mark_native_bad);
    }
    // 三条都试完（无候选）→ 上抛
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(server, .{
        .transient_retries = 2,
        .remaining_fallbacks = 0,
    }).action));
    // 第二次换方言要求预算（fallback_allowed=false）→ 上抛
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(server, .{
        .transient_retries = 2,
        .remaining_fallbacks = 1,
        .fallback_allowed = false,
    }).action));
    // 预算用尽：同方言不再重试，但首次换方言仍给机会（不必再等空闲超时）
    try std.testing.expectEqual(Action.retry_dialect, std.meta.activeTag(decideFailure(timeout, .{
        .within_budget = false,
        .remaining_fallbacks = 1,
    }).action));
}

test "fallbackOrder: 每个方言都指向另外两个（三方言互备环）" {
    try std.testing.expectEqualSlices(Dialect, &.{ .responses, .anthropic }, &fallbackOrder(.openai));
    try std.testing.expectEqualSlices(Dialect, &.{ .openai, .anthropic }, &fallbackOrder(.responses));
    try std.testing.expectEqualSlices(Dialect, &.{ .openai, .responses }, &fallbackOrder(.anthropic));
}

test "decideFailure: 真错误直接上抛" {
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(.{ .status = 401, .code = "AUTH", .message = "", .retry_after_ms = null }, .{}).action));
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(.{ .status = 400, .code = "CONTEXT_WINDOW_EXCEEDED", .message = "", .retry_after_ms = null }, .{}).action));
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(.{ .status = 400, .code = "INVALID_REQUEST", .message = "", .retry_after_ms = null }, .{}).action));
}

test "synthesizeTransportFailure: 看门狗/断连类错误 → TIMEOUT（可重试）" {
    try std.testing.expectEqualStrings("TIMEOUT", synthesizeTransportFailure(error.ConnectionResetByPeer).code);
    try std.testing.expectEqualStrings("TIMEOUT", synthesizeTransportFailure(error.ConnectionTimedOut).code);
    try std.testing.expectEqualStrings("TIMEOUT", synthesizeTransportFailure(error.SocketUnconnected).code);
    try std.testing.expectEqual(@as(u16, 504), synthesizeTransportFailure(error.ConnectionResetByPeer).status);
    // 其它未知错误仍是 SERVER（同样可重试，语义保守）
    try std.testing.expectEqualStrings("SERVER", synthesizeTransportFailure(error.Unexpected).code);
    // TLS 握手/证书失败：std 折叠成一个错误名，网关给出可行动文案（仍是 SERVER，可重试）
    const tls_failure = synthesizeTransportFailure(error.TlsInitializationFailed);
    try std.testing.expectEqualStrings("SERVER", tls_failure.code);
    try std.testing.expect(std.mem.indexOf(u8, tls_failure.message, "TLS handshake failed") != null);
}

test "decideFailure: TIMEOUT 与 5xx 同档退避重试" {
    const timeout = Failure{ .status = 504, .code = "TIMEOUT", .message = "ConnectionResetByPeer", .retry_after_ms = null };
    try std.testing.expectEqual(@as(u64, 2000), decideFailure(timeout, .{}).action.transient);
    try std.testing.expectEqual(@as(u64, 5000), decideFailure(timeout, .{ .transient_retries = 1 }).action.transient);
    try std.testing.expectEqual(Action.give_up, std.meta.activeTag(decideFailure(timeout, .{ .transient_retries = 2 }).action));
}
