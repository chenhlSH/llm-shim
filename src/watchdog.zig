//! 占位保活看门狗：网关进程级单线程。
//!
//! 为什么需要独立线程：Zig 0.17 的 `std.http.Client` 不支持读超时，上游读取是
//! 阻塞的（`NetRead` 无 timeout 字段；`SO_RCVTIMEO` 触发的 EAGAIN 在 std 里是
//! `errnoBug` 会 panic）。"上游静默 ≥ 阈值 → 向客户端注入占位帧"只能由另一个
//! 线程计时。
//!
//! 并发纪律：客户端写入（请求线程的真实帧 / 看门狗的占位帧）统一经 entry.mutex
//! 串行；请求在收尾（错误帧/正常 done）前先置 `finished`，看门狗见标志即跳过，
//! 避免占位帧插进收尾帧中间。
//!
//! 只有"流式"请求注册；非流式无法中途写 JSON（文档已注明）。
const std = @import("std");
const clock = @import("clock.zig");
const placeholder_mod = @import("placeholder.zig");
const env = @import("env.zig");
const http_util = @import("http_util.zig");
const inbound_openai = @import("inbound/openai.zig");
const inbound_anthropic = @import("inbound/anthropic.zig");
const inbound_responses = @import("inbound/responses.zig");

pub const Dialect = enum { openai, anthropic, responses };

/// 上游空闲超时默认值：600s（0=关）。10 分钟覆盖长思考，同时给黑洞上游一个有界的失败期限。
pub const default_idle_timeout_ms: u64 = 600_000;
pub const idle_timeout_env = "AUTO_COMPAT_IDLE_TIMEOUT_MS";

/// 有效空闲超时（毫秒）：唯一事实来源（endpoint 与启动日志都用它，避免默认值漂移）。
pub fn idleTimeoutMs() u64 {
    const raw = env.get(idle_timeout_env) orelse return default_idle_timeout_ms;
    return std.fmt.parseInt(u64, raw, 10) catch default_idle_timeout_ms;
}

/// 一个在途流式请求的注册条目。生命周期：网关 handler 的栈帧；
/// `register` 与 `unregister` 严格配对（unregister 在 defer 里，先于栈退栈）。
pub const Entry = struct {
    io: std.Io,
    dialect: Dialect,
    /// *inbound_*.StreamOut（按 dialect 解引用）；非流式请求为 null（只能做空闲超时）。
    stream_out: ?*anyopaque,
    /// 流式响应体；非流式请求为 null（占位注入跳过）。
    body: ?*std.http.BodyWriter,
    /// 客户端写入互斥锁（请求线程与看门狗共用）
    mutex: *std.Io.Mutex,
    /// 是否已发过占位帧（网关据"只发过占位仍可重试"决定自愈语义）
    placeholder_sent: *bool,
    /// 上次向客户端写出的时间戳（真实帧与占位帧都会更新）
    last_write_ms: *std.atomic.Value(i64),
    /// 请求已收尾（收尾帧写出前先置位）
    finished: *std.atomic.Value(bool),
    /// 上游最近一次有字节到达的时间（请求线程每个 chunk 更新）——空闲超时的依据。
    last_chunk_ms: *std.atomic.Value(i64),
    /// 空闲超时（0=关）：静默超过它 → shutdown 上游 socket 打断阻塞读。
    idle_timeout_ms: u64,
    /// 已被看门狗打断（适配器据此把读错误/EOF 归类为 TIMEOUT 而非 MALFORMED）。
    timed_out: *std.atomic.Value(bool),
    /// 上游连接句柄（适配器建连后经线程绑定回填；未回填时不能打断）。
    upstream_handle: ?std.c.fd_t = null,
};

/// 当前线程在途请求的条目（网关 handler 在 callHealed 前后 bind/unbind；
/// 适配器经 `noteUpstreamSocket` / `upstreamTimedOut` 读写它——同线程，无竞争）。
threadlocal var current_entry: ?*Entry = null;

pub fn bindCurrent(entry: *Entry) void {
    current_entry = entry;
}

pub fn unbindCurrent() void {
    current_entry = null;
}

/// 每次上游尝试开始前调用：重置打断标志/计时/句柄（自愈重试时重新武装）。
pub fn beginAttempt() void {
    const entry = current_entry orelse return;
    entry.mutex.lockUncancelable(entry.io);
    defer entry.mutex.unlock(entry.io);
    entry.timed_out.store(false, .release);
    entry.last_chunk_ms.store(clock.unixMilli(), .release);
    entry.upstream_handle = null;
}

/// 适配器建连后回填上游 socket（未绑定/未启用时空操作）。
pub fn noteUpstreamSocket(socket: std.c.fd_t) void {
    const entry = current_entry orelse {
        if (env.get("AUTO_COMPAT_DEBUG") != null) std.debug.print("[watchdog] noteUpstreamSocket: no bound entry (skipped)\n", .{});
        return;
    };
    if (env.get("AUTO_COMPAT_DEBUG") != null) std.debug.print("[watchdog] upstream socket bound: handle={}\n", .{socket}); // {} 兼容 POSIX fd(i32) 与 Windows HANDLE(指针)
    entry.mutex.lockUncancelable(entry.io);
    defer entry.mutex.unlock(entry.io);
    entry.upstream_handle = socket;
}

/// 本请求是否已被空闲超时打断（适配器据此分类失败原因）。
pub fn upstreamTimedOut() bool {
    const entry = current_entry orelse return false;
    return entry.timed_out.load(.acquire);
}

var registry_mutex: std.Io.Mutex = .init;
var registry_io: std.Io = undefined;
var registry_allocator: std.mem.Allocator = undefined;
/// 注册表存**指针**：注销按地址匹配，且绝不能拷贝（拷贝会指向已退栈的 handler 栈帧）。
var entries: std.ArrayList(*Entry) = .empty;
/// 看门狗线程是否已真正启动（未启动时 register/unregister 为空操作，
/// 也保证单测/未启用的进程不会去碰未初始化的注册表）。
var started = false;

/// 启动看门狗（幂等；仅在占位保活开启时真正起线程）。由 runGateway 调用一次。
pub fn start(allocator: std.mem.Allocator, io: std.Io) void {
    registry_io = io;
    registry_allocator = allocator;
    if (!placeholder_mod.enabled()) return;
    const threshold = placeholder_mod.thresholdMs();
    const thread = std.Thread.spawn(.{}, loop, .{ io, threshold }) catch |err| {
        std.debug.print("[auto-compat-zig] watchdog thread failed to start ({s}); placeholder keepalive disabled\n", .{@errorName(err)});
        return;
    };
    started = true;
    thread.detach();
}

fn loop(io: std.Io, threshold_ms: u64) void {
    // tick 取阈值的 1/2 且落在 [50ms, 1000ms]：e2e 的小阈值快档也能及时触发。
    const tick_ms: u64 = @max(@as(u64, 50), @min(@as(u64, 1000), threshold_ms / 2));
    while (true) {
        clock.sleepMilli(tick_ms);
        const now = clock.unixMilli();
        registry_mutex.lockUncancelable(io);
        defer registry_mutex.unlock(io);
        for (entries.items) |entry| {
            if (entry.finished.load(.acquire)) continue;
            // 空闲超时：静默超过 idle_timeout_ms → 打断上游阻塞读（只打一次）。
            if (entry.idle_timeout_ms > 0 and !entry.timed_out.load(.acquire)) {
                const last_chunk = entry.last_chunk_ms.load(.acquire);
                if (now - last_chunk >= @as(i64, @intCast(entry.idle_timeout_ms))) {
                    interruptUpstream(entry, now - last_chunk);
                    continue; // 本 tick 不再注入占位（请求即将以 TIMEOUT 收尾）
                }
            }
            const last = entry.last_write_ms.load(.acquire);
            if (now - last < @as(i64, @intCast(threshold_ms))) continue;
            emitPlaceholder(entry, now, last);
        }
    }
}

/// 上游空闲超时：shutdown 上游 socket 打断阻塞读（跨平台经 std.c.shutdown）。
/// 读会以连接中断类错误返回或 EOF；适配器经 `upstreamTimedOut()` 把两种情况都归为 TIMEOUT。
fn interruptUpstream(entry: *Entry, silent_ms: i64) void {
    entry.mutex.lockUncancelable(entry.io);
    defer entry.mutex.unlock(entry.io);
    if (entry.finished.load(.acquire)) return;
    const handle = entry.upstream_handle orelse {
        if (env.get("AUTO_COMPAT_DEBUG") != null) std.debug.print("[watchdog] idle timeout fired but upstream socket is not bound yet; waiting\n", .{});
        return; // 还没建连成功：等下一 tick
    };
    entry.timed_out.store(true, .release);
    shutdownHandle(handle);
    std.debug.print("[auto-compat-zig] upstream idle timeout: silent for {d}ms (limit {d}ms), interrupting the blocked read (code=TIMEOUT)\n", .{ silent_ms, entry.idle_timeout_ms });
}

/// shutdown 的跨平台 how 常量（Linux=SHUT_RDWR=2，Windows=SD_BOTH=2）。
const shutdown_both: c_int = 2;

/// 打断阻塞读的跨平台 shutdown。
/// - POSIX：std.c.shutdown（linux 经 libc）；
/// - Windows：std.c.shutdown 在 mingw 下缺 ws2_32 导入，这里自声明 extern "ws2_32"
///   （与 kernel32.Sleep 自声明同一手法），并在 build.zig 里为 Windows 目标链 ws2_32。
fn shutdownHandle(handle: std.c.fd_t) void {
    if (builtin.os.tag == .windows) {
        // Windows 的 SOCKET 是 usize（不是 HANDLE 指针形态）
        _ = shutdown(@intFromPtr(handle), shutdown_both);
    } else {
        _ = std.c.shutdown(handle, shutdown_both);
    }
}

/// 符号名必须与 ws2_32 的导出名一致（"shutdown"）；参数是 SOCKET(usize)。
extern "ws2_32" fn shutdown(socket: usize, how: c_int) callconv(.winapi) c_int;

const builtin = @import("builtin");

/// 纯函数：本 tick 是否应判定空闲超时（便于单测）。
pub fn shouldInterrupt(now_ms: i64, last_chunk_ms: i64, idle_timeout_ms: u64, already_timed_out: bool) bool {
    if (already_timed_out or idle_timeout_ms == 0) return false;
    return now_ms - last_chunk_ms >= @as(i64, @intCast(idle_timeout_ms));
}

/// 向客户端注入占位帧。返回前已持锁写完全部帧。
/// 工具/思考块打开中（方言自身的 writePlaceholder 返回空）→ 本 tick 跳过，
/// 不更新时间戳（下一个 tick 再试，块关闭后就能注入）。
fn emitPlaceholder(entry: *Entry, now: i64, last: i64) void {
    entry.mutex.lockUncancelable(entry.io);
    defer entry.mutex.unlock(entry.io);
    if (entry.finished.load(.acquire)) return; // 拿锁期间请求已收尾
    const raw_out = entry.stream_out orelse return; // 非流式：无法中途注入占位
    const body = entry.body orelse return;
    const frames = switch (entry.dialect) {
        .openai => @as(*inbound_openai.StreamOut, @ptrCast(@alignCast(raw_out))).writePlaceholder(placeholder_mod.text) catch return,
        .anthropic => @as(*inbound_anthropic.StreamOut, @ptrCast(@alignCast(raw_out))).writePlaceholder(placeholder_mod.text) catch return,
        .responses => @as(*inbound_responses.StreamOut, @ptrCast(@alignCast(raw_out))).writePlaceholder(placeholder_mod.text) catch return,
    };
    if (frames.len == 0) return;
    for (frames) |frame| {
        body.writer.writeAll(frame) catch {
            // 写失败 = 客户端已离开：标记收尾，后续 tick 不再尝试。
            entry.finished.store(true, .release);
            return;
        };
    }
    http_util.flushBody(body) catch {
        // 写失败 = 客户端已离开：标记收尾，后续 tick 不再尝试。
        entry.finished.store(true, .release);
        return;
    };
    entry.placeholder_sent.* = true;
    entry.last_write_ms.store(now, .release);
    std.debug.print("[auto-compat-zig] placeholder keepalive: injected after {d}ms of upstream silence (streaming only; AUTO_COMPAT_PLACEHOLDER_MS=0 disables)\n", .{now - last});
}

/// 注册/注销（未启用时为空操作；成对调用）。
pub fn register(entry: *Entry) void {
    if (!started) return;
    registry_mutex.lockUncancelable(registry_io);
    defer registry_mutex.unlock(registry_io);
    entries.append(registry_allocator, entry) catch {};
}

pub fn unregister(entry: *Entry) void {
    if (!started) return;
    registry_mutex.lockUncancelable(registry_io);
    defer registry_mutex.unlock(registry_io);
    for (entries.items, 0..) |existing, index| {
        if (existing != entry) continue;
        _ = entries.swapRemove(index);
        return;
    }
}

/// 纯函数：本 tick 是否应注入占位（便于单测；loop 里的判断与之一致）。
pub fn shouldInject(now_ms: i64, last_write_ms: i64, threshold_ms: u64) bool {
    if (threshold_ms == 0) return false;
    return now_ms - last_write_ms >= @as(i64, @intCast(threshold_ms));
}

test "shouldInject: 阈值判定与关闭态" {
    try std.testing.expect(!shouldInject(1000, 1000, 55_000)); // 刚写过：静默 0ms
    try std.testing.expect(!shouldInject(55_999, 1000, 55_000)); // 静默 54_999ms
    try std.testing.expect(shouldInject(56_000, 1000, 55_000)); // 静默恰好 55_000ms
    try std.testing.expect(shouldInject(60_000, 1000, 55_000));
    try std.testing.expect(!shouldInject(60_000, 1000, 0)); // 关闭
}

test "register/unregister: 看门狗未启动时为空操作（不碰未初始化注册表）" {
    var mutex: std.Io.Mutex = .init;
    var sent = false;
    var last = std.atomic.Value(i64).init(0);
    var last_chunk = std.atomic.Value(i64).init(0);
    var timed_out = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    var stream_out_placeholder: usize = 0; // 仅作地址占位，不真正调用
    var body: std.http.BodyWriter = undefined;
    var entry = Entry{
        .io = std.testing.io,
        .dialect = .openai,
        .stream_out = @ptrCast(&stream_out_placeholder),
        .body = &body,
        .mutex = &mutex,
        .placeholder_sent = &sent,
        .last_write_ms = &last,
        .finished = &finished,
        .last_chunk_ms = &last_chunk,
        .idle_timeout_ms = 0,
        .timed_out = &timed_out,
    };
    // 测试进程从未调用 start()（也不该为跑循环而启动线程）→ 空操作且不崩溃
    register(&entry);
    unregister(&entry);
    try std.testing.expect(entries.items.len == 0);
}

test "shouldInterrupt: 空闲超时判定（关闭/已打断/边界；字面量与默认值无关）" {
    try std.testing.expect(!shouldInterrupt(1000, 1000, 10_000, false)); // 刚有字节
    try std.testing.expect(!shouldInterrupt(10_999, 1000, 10_000, false)); // 静默 9_999ms
    try std.testing.expect(shouldInterrupt(11_000, 1000, 10_000, false)); // 恰好到阈值
    try std.testing.expect(!shouldInterrupt(400_000, 1000, 0, false)); // 关闭
    try std.testing.expect(!shouldInterrupt(400_000, 1000, 10_000, true)); // 已打断过
}

test "idle timeout: 默认 600s（0.1.4 起；唯一事实来源）" {
    try std.testing.expectEqual(@as(u64, 600_000), default_idle_timeout_ms);
    try std.testing.expectEqualStrings("AUTO_COMPAT_IDLE_TIMEOUT_MS", idle_timeout_env);
}
