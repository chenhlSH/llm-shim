//! 供应商剖面：内置两家（实测数据）+ providers.json 装载（自定义条目）。
const std = @import("std");
const types = @import("types.zig");
const env = @import("env.zig");
const probe_mod = @import("probe.zig");

pub const Protocol = types.Protocol;
pub const EffortStrategy = types.EffortStrategy;

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    context_window: u64,
    vision: bool,
};

pub const Alias = types.Alias;

pub const Profile = struct {
    /// 路由 id（也是网关模型前缀 name/model）。
    name: []const u8,
    display_name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    protocol: Protocol,
    models: []const Model,
    aliases: []const Alias = &.{},
    effort_strategy: EffortStrategy = .omit_always,
    effort_wire: enum { reasoning_effort, reasoning } = .reasoning_effort,
    reasoning_delta_fields: []const []const u8 = &.{"reasoning_content"},
    honors_stop: bool = true,
    /// anthropic 上游的 thinking 映射（openai/responses 忽略）。
    thinking_strategy: types.ThinkingStrategy = .omit,
    free: bool = false,
    detected: bool = false,
    default_max_tokens: u64 = 32_768,
    /// 探针固化：非空时目录收窄到这些模型。
    verified_models: ?[]const []const u8 = null,
    /// 探针固化：false = 档位永不透传。
    effort_accepted: ?bool = null,
    /// 内置剖面（实测怪癖数据）——同端点去重日志据此说明"内置优先"。
    builtin: bool = false,
};

const intern_ai_models = [_]Model{
    .{ .id = "glm-5.3", .name = "GLM-5.3", .context_window = 1_048_576, .vision = false },
    .{ .id = "deepseek-v4-flash-vision", .name = "DeepSeek V4 Flash Vision", .context_window = 1_048_576, .vision = true },
};

const amd_models = [_]Model{
    .{ .id = "MiMo-V2.6-Flash", .name = "MiMo V2.6 Flash", .context_window = 1_048_576, .vision = true },
    .{ .id = "GLM-5.3-Flash", .name = "GLM-5.3 Flash", .context_window = 262_144, .vision = false },
};

const amd_aliases = [_]Alias{
    .{ .from = "mimo-v2.6-flash", .to = "MiMo-V2.6-Flash" },
    .{ .from = "glm-5.3-flash", .to = "GLM-5.3-Flash" },
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(Profile),

    pub fn deinit(self: *Registry) void {
        for (self.profiles.items) |profile| {
            if (profile.verified_models) |verified| self.allocator.free(verified);
        }
        self.profiles.deinit(self.allocator);
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Profile {
        for (self.profiles.items) |*profile| {
            if (std.mem.eql(u8, profile.name, name)) return profile;
        }
        return null;
    }
};

/// 内置两家（实测剖面，TS 版 vendors/*.models.ts 的对应物）。
pub fn builtinRegistry(allocator: std.mem.Allocator) !Registry {
    var profiles: std.ArrayList(Profile) = .empty;
    try profiles.append(allocator, .{
        .name = "intern-ai",
        .display_name = "InternAI Discovery",
        .base_url = "https://discovery-api.intern-ai.org.cn/v1",
        .api_key_env = "INTERN_AI_API_KEY",
        .protocol = .openai,
        .models = &intern_ai_models,
        .effort_strategy = .passthrough_off_none,
        .reasoning_delta_fields = &.{"reasoning_content"},
        .honors_stop = true,
        .free = false,
        .builtin = true,
    });
    try profiles.append(allocator, .{
        .name = "amd-radeon",
        .display_name = "AMD Radeon Cloud",
        .base_url = "https://developer.amd.com.cn/radeon/api/v1",
        .api_key_env = "AMD_RADEON_API_KEY",
        .protocol = .openai,
        .models = &amd_models,
        .aliases = &amd_aliases,
        .effort_strategy = .glm_clamp,
        .reasoning_delta_fields = &.{ "reasoning", "reasoning_content" },
        .honors_stop = false,
        .free = true,
        .builtin = true,
    });
    return .{ .allocator = allocator, .profiles = profiles };
}

/// 固化/写回用的 provider 条目（统一 upsert 的输入）。
pub const ProviderEntry = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    protocol: Protocol,
    preset: ?[]const u8 = null,
    verified_models: ?[]const []const u8 = null,
    effort_accepted: ?bool = null,
};

/// 按 name upsert 到 providers.json 文本（TS: mergeFrozenProviders 的 frozen-wins 语义）：
/// 新条目覆盖同名的 baseURL/apiKeyEnv/protocol（及可选的 preset/verifiedModels/effortAccepted），
/// 既有条目的其它字段原样保留；name 不存在的追加到末尾。逗号交给 Stringify 状态机（避免 ",,"）。
pub fn upsertProviders(arena: std.mem.Allocator, existing_text: ?[]const u8, entries: []const ProviderEntry) ![]const u8 {
    var items: std.ArrayList(std.json.ObjectMap) = .empty;

    // 1) 既有条目（仅对象）原样保留；解析失败按空文档处理
    if (existing_text) |text| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})) |parsed| {
            if (parsed == .array) {
                for (parsed.array.items) |item| {
                    if (item != .object) continue;
                    try items.append(arena, item.object);
                }
            }
        } else |_| {}
    }

    // 2) 逐条 upsert
    for (entries) |entry| {
        var target: ?*std.json.ObjectMap = null;
        for (items.items) |*map| {
            const name_value = map.get("name") orelse continue;
            if (name_value == .string and std.mem.eql(u8, name_value.string, entry.name)) {
                target = map;
                break;
            }
        }
        if (target == null) {
            try items.append(arena, std.json.ObjectMap.empty);
            target = &items.items[items.items.len - 1];
        }
        const map = target.?;
        try map.put(arena, "name", .{ .string = try arena.dupe(u8, entry.name) });
        try map.put(arena, "baseURL", .{ .string = try arena.dupe(u8, entry.base_url) });
        try map.put(arena, "apiKeyEnv", .{ .string = try arena.dupe(u8, entry.api_key_env) });
        try map.put(arena, "protocol", .{ .string = @tagName(entry.protocol) });
        if (entry.preset) |preset| try map.put(arena, "preset", .{ .string = try arena.dupe(u8, preset) });
        if (entry.verified_models) |verified| {
            var list: std.json.Array = .init(arena);
            for (verified) |model_id| try list.append(.{ .string = try arena.dupe(u8, model_id) });
            try map.put(arena, "verifiedModels", .{ .array = list });
        }
        if (entry.effort_accepted) |accepted| try map.put(arena, "effortAccepted", .{ .bool = accepted });
    }

    // 3) stringify（自动补逗号）
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginArray();
    for (items.items) |map| try stringify.write(std.json.Value{ .object = map });
    try stringify.endArray();
    return out.written();
}

/// 原子写文本文件（临时文件 + rename；已存在则 replace，否则 link）——
/// 供探针固化与网关运行时写回共用。
pub fn writeTextAtomic(io: std.Io, path: []const u8, text: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const exists = blk: {
        var probe_file = dir.openFile(io, path, .{}) catch break :blk false;
        probe_file.close(io);
        break :blk true;
    };
    var atomic = try dir.createFileAtomic(io, path, .{ .replace = exists });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    if (exists) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
}

/// 端点归一化比较：去尾斜杠 + ASCII 大小写不敏感（两个 URL 视为同一端点）。
/// 探针（probe.zig）固化改名也用同一规则。
pub fn sameEndpoint(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

/// 同端点条目已归谁所有；同名剖面返回 null（同名走"覆盖既有 profile"语义，不算重复注册）。
fn endpointOwner(registry: *const Registry, name: []const u8, base_url: []const u8) ?*const Profile {
    for (registry.profiles.items) |*existing| {
        if (std.mem.eql(u8, existing.name, name)) continue;
        if (sameEndpoint(existing.base_url, base_url)) return existing;
    }
    return null;
}

/// 去重日志：用户要求讲清楚代价——条目被冷落、其固化信息不生效。
/// 保持 ASCII（Windows 传统代码页下中文日志会乱码，与菜单文本同一纪律）。
fn logEndpointDuplicate(entry_name: []const u8, owner: *const Profile, base_url: []const u8) void {
    std.debug.print(
        "[llm-shim] providers.json: entry \"{s}\" resolves to the same endpoint as {s} \"{s}\" ({s}) -- same endpoint = same provider; keeping \"{s}\", ignoring the entry (its apiKeyEnv/verifiedModels/effortAccepted will NOT apply). Use a different baseURL for an independent provider.\n",
        .{ entry_name, if (owner.builtin) "built-in" else "earlier-registered", owner.name, base_url, owner.name },
    );
}

/// providers.json 装载（与 TS 版 schema 兼容）。
/// 字段：{name, preset?, baseURL, apiKeyEnv, protocol?, verifiedModels?, effortAccepted?}
/// baseURL 允许裸站点：装载期做路径自动发现 + 目录探测；失败也不阻塞——
/// 网关运行时的路由自愈（src/router.zig）会继续兜底并在成功后写回本文件。
pub fn loadRegistry(allocator: std.mem.Allocator, io: std.Io) !Registry {
    return loadRegistryWith(allocator, io, null);
}

/// path_override 为 null 时按 AUTO_COMPAT_PROVIDERS_FILE / ./providers.json 取路径
/// （单测注入固定路径用，避免碰进程环境）。
pub fn loadRegistryWith(allocator: std.mem.Allocator, io: std.Io, path_override: ?[]const u8) !Registry {
    var registry = try builtinRegistry(allocator);
    errdefer registry.deinit();

    const path = path_override orelse env.getOr("AUTO_COMPAT_PROVIDERS_FILE", "providers.json");
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return registry,
        else => return err,
    };
    defer allocator.free(text);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch {
        std.debug.print("[llm-shim] providers.json parse failed, ignoring custom entries\n", .{});
        return registry;
    };
    const root = switch (parsed) {
        .array => |array| array,
        else => return registry,
    };
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    for (root.items) |item| {
        if (item != .object) continue;
        const object = item.object;
        const name = jsonGetString(object, "name") orelse continue;
        const base_url = jsonGetString(object, "baseURL") orelse continue;
        const api_key_env = jsonGetString(object, "apiKeyEnv") orelse continue;

        // 同端点去重（内置优先）：custom-N 探同一端点会得到与内置完全相同的目录，
        // 裸模型 id 必然歧义。这里先用原始 URL 判定并短路（不触发任何网络探测）；
        // 裸站点解析后再复核一次（见下方 resolved 分支）。同名条目不算重复（走覆盖语义）。
        if (endpointOwner(&registry, name, base_url)) |owner| {
            logEndpointDuplicate(name, owner, base_url);
            continue;
        }

        const preset = jsonGetString(object, "preset");
        const protocol: Protocol = if (jsonGetString(object, "protocol")) |protocol_text| blk: {
            if (std.mem.eql(u8, protocol_text, "anthropic")) break :blk .anthropic;
            if (std.mem.eql(u8, protocol_text, "responses")) break :blk .responses;
            break :blk .openai;
        } else .openai;

        var verified_models: ?[]const []const u8 = null;
        if (object.get("verifiedModels")) |verified_value| {
            if (verified_value == .array) {
                var verified: std.ArrayList([]const u8) = .empty;
                for (verified_value.array.items) |entry| {
                    if (entry == .string) try verified.append(allocator, try allocator.dupe(u8, entry.string));
                }
                if (verified.items.len > 0) verified_models = try verified.toOwnedSlice(allocator);
            }
        }
        const effort_accepted: ?bool = if (object.get("effortAccepted")) |value| switch (value) {
            .bool => |boolean| boolean,
            else => null,
        } else null;

        // 自定义条目的档位策略（与 TS 版一致）：
        // effortAccepted=false → 永不透传；openrouter 预设 → reasoning 对象形态；
        // 其他已知预设 → off 省略其余透传；未知厂商 → 永不透传。
        var effort_strategy: EffortStrategy = .omit_always;
        var effort_wire: @TypeOf(@as(Profile, undefined).effort_wire) = .reasoning_effort;
        if (preset) |preset_id| {
            if (std.mem.eql(u8, preset_id, "openrouter")) {
                effort_strategy = .passthrough_off_omit;
                effort_wire = .reasoning;
            } else if (std.mem.eql(u8, preset_id, "intern-ai")) {
                effort_strategy = .passthrough_off_none;
            } else if (std.mem.eql(u8, preset_id, "siliconflow") or
                std.mem.eql(u8, preset_id, "modelscope") or
                std.mem.eql(u8, preset_id, "volcengine-ark") or
                std.mem.eql(u8, preset_id, "zhipu"))
            {
                effort_strategy = .passthrough_off_omit;
            }
        }
        if (effort_accepted == false) effort_strategy = .omit_always;

        // URL 宽容 + 目录探测：裸站点自动发现后缀，/models 拉目录（能力推断）。
        var resolved_base = base_url;
        var models: std.ArrayList(Model) = .empty;
        var detection_ok = false;
        // 探测可能耗时（不可达端点要扫候选后缀、每次间隔 300ms 节流）：先点名，避免启动期静默像卡死。
        std.debug.print("[llm-shim] providers: entry \"{s}\": resolving {s} (path discovery; an unreachable endpoint can take ~10s)\n", .{ name, base_url });
        if (probe_mod.resolveApiBase(allocator, &client, base_url, env.get(api_key_env))) |resolved| {
            if (resolved) |base| {
                // 复核：裸站点解析出的端点若与已注册供应商相同，同样收敛（早判短路失败时的兜底）。
                if (endpointOwner(&registry, name, base)) |owner| {
                    logEndpointDuplicate(name, owner, base);
                    allocator.free(base);
                    if (verified_models) |verified| {
                        for (verified) |model_id| allocator.free(model_id);
                        allocator.free(verified);
                    }
                    continue;
                }
                resolved_base = base;
                if (probe_mod.detectModels(allocator, &client, base, env.get(api_key_env))) |detected| {
                    detection_ok = true;
                    for (detected) |model| {
                        // verifiedModels 冻结：目录收窄到验证过的模型
                        if (verified_models) |verified| {
                            var keep = false;
                            for (verified) |model_id| {
                                if (std.mem.eql(u8, model_id, model.id)) keep = true;
                            }
                            if (!keep) continue;
                        }
                        try models.append(allocator, .{
                            .id = model.id,
                            .name = if (model.name.len > 0) model.name else model.id,
                            .context_window = model.context_window orelse 131_072,
                            .vision = model.vision,
                        });
                    }
                } else |_| {}
            }
        } else |_| {}
        if (!detection_ok) {
            if (verified_models) |verified| {
                // 探测失败但有冻结条目：退化用冻结模型名
                for (verified) |model_id| {
                    try models.append(allocator, .{ .id = model_id, .name = model_id, .context_window = 131_072, .vision = false });
                }
            }
        }

        const final_base_url = try allocator.dupe(u8, resolved_base);
        const final_models = try models.toOwnedSlice(allocator);

        // 同名条目 = 覆盖既有 profile 的路由字段（内置 provider 的被学习路径重启后生效），
        // 而不是追加重复条目。厂商怪癖字段（aliases/honors_stop/档位策略等）仅在条目
        // 显式给出信号（preset/effortAccepted）时才覆盖，避免持久化回写把内置剖面改坏。
        var replaced = false;
        for (registry.profiles.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, name)) continue;
            existing.base_url = final_base_url;
            existing.protocol = protocol;
            if (final_models.len > 0) existing.models = final_models;
            existing.detected = detection_ok;
            if (verified_models) |verified| {
                if (existing.verified_models) |old| allocator.free(old);
                existing.verified_models = verified;
            }
            if (effort_accepted) |accepted| {
                existing.effort_accepted = accepted;
                if (!accepted) existing.effort_strategy = .omit_always;
            }
            if (preset != null) {
                existing.effort_strategy = effort_strategy;
                existing.effort_wire = effort_wire;
            }
            replaced = true;
            break;
        }
        if (replaced) continue;

        try registry.profiles.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .display_name = if (preset) |preset_id| (if (findPreset(preset_id)) |p| p.display_name else try allocator.dupe(u8, name)) else try allocator.dupe(u8, name),
            .base_url = final_base_url,
            .api_key_env = try allocator.dupe(u8, api_key_env),
            .protocol = protocol,
            .models = final_models,
            .effort_strategy = effort_strategy,
            .effort_wire = effort_wire,
            .reasoning_delta_fields = &.{ "reasoning_content", "reasoning" },
            .honors_stop = true,
            .free = preset != null,
            .detected = detection_ok,
            .verified_models = verified_models,
            .effort_accepted = effort_accepted,
        });
    }
    return registry;
}

fn findPreset(id: []const u8) ?*const @import("probe.zig").Preset {
    return @import("probe.zig").findPreset(id);
}

fn jsonGetString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

test "upsertProviders: 同名覆盖 baseURL/protocol，保留其它字段，追加新 name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const existing =
        \\[
        \\  {"name":"a","baseURL":"https://old.example/v1","apiKeyEnv":"A_KEY","preset":"zhipu","verifiedModels":["m1"],"effortAccepted":true}
        \\]
    ;
    const entries = [_]ProviderEntry{
        .{ .name = "a", .base_url = "https://new.example/api/v1", .api_key_env = "A_KEY", .protocol = .anthropic },
        .{ .name = "b", .base_url = "https://b.example/v1", .api_key_env = "B_KEY", .protocol = .openai, .preset = "intern-ai" },
    };
    const merged = try upsertProviders(arena, existing, &entries);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, merged, .{});
    try std.testing.expect(parsed == .array);
    try std.testing.expectEqual(@as(usize, 2), parsed.array.items.len);

    const first = parsed.array.items[0].object;
    try std.testing.expectEqualStrings("https://new.example/api/v1", first.get("baseURL").?.string);
    try std.testing.expectEqualStrings("anthropic", first.get("protocol").?.string);
    try std.testing.expectEqualStrings("zhipu", first.get("preset").?.string);
    try std.testing.expectEqualStrings("m1", first.get("verifiedModels").?.array.items[0].string);
    try std.testing.expect(first.get("effortAccepted").?.bool);

    try std.testing.expectEqualStrings("b", parsed.array.items[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("intern-ai", parsed.array.items[1].object.get("preset").?.string);
}

test "upsertProviders: 空文档/坏 JSON/二次合并幂等" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]ProviderEntry{
        .{ .name = "x", .base_url = "https://x.example/api/v1", .api_key_env = "X_KEY", .protocol = .openai, .verified_models = &.{ "m1", "m2" } },
        .{ .name = "y", .base_url = "https://y.example/v1", .api_key_env = "Y_KEY", .protocol = .responses, .effort_accepted = false },
    };

    // 空文档 + 2 条：必须合法 JSON（历史 bug：Stringify 自动逗号 + 手工逗号 → ",,"）
    const first_pass = try upsertProviders(arena, null, &entries);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, first_pass, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.array.items[0].object.get("verifiedModels").?.array.items.len);
    try std.testing.expect(!parsed.array.items[1].object.get("effortAccepted").?.bool);

    // 二次合并同样的条目：按 name 去重，不追加
    const second_pass = try upsertProviders(arena, first_pass, &entries);
    const parsed_again = try std.json.parseFromSliceLeaky(std.json.Value, arena, second_pass, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed_again.array.items.len);

    // 坏 JSON：忽略并仅输出新条目
    const third_pass = try upsertProviders(arena, "{not json", &entries);
    const parsed_third = try std.json.parseFromSliceLeaky(std.json.Value, arena, third_pass, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed_third.array.items.len);
}

test "builtinRegistry: 两家内置剖面" {
    var registry = try builtinRegistry(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 2), registry.profiles.items.len);
    const intern_ai = registry.find("intern-ai").?;
    try std.testing.expectEqual(Protocol.openai, intern_ai.protocol);
    try std.testing.expectEqualStrings("https://discovery-api.intern-ai.org.cn/v1", intern_ai.base_url);
    const amd = registry.find("amd-radeon").?;
    try std.testing.expectEqual(false, amd.honors_stop);
    try std.testing.expectEqual(@as(usize, 2), amd.aliases.len);
}

test "sameEndpoint/endpointOwner: 归一化比较、同名不归并" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(sameEndpoint("https://a.example/v1", "https://a.example/v1/"));
    try std.testing.expect(sameEndpoint("HTTPS://A.example/V1", "https://a.example/v1"));
    try std.testing.expect(!sameEndpoint("https://a.example/v1", "https://a.example/v2"));
    try std.testing.expect(!sameEndpoint("http://a.example/v1", "https://a.example/v1"));

    var registry = try builtinRegistry(arena);
    defer registry.deinit();

    const intern_url = "https://discovery-api.intern-ai.org.cn/v1";
    // 同名条目 → 不算重复注册（走"覆盖既有 profile"语义）
    try std.testing.expect(endpointOwner(&registry, "intern-ai", intern_url) == null);
    // 不同名同端点（尾斜杠/大小写归一化）→ 归并到内置
    const owner = endpointOwner(&registry, "custom-1", "HTTPS://discovery-api.intern-ai.org.cn/v1/").?;
    try std.testing.expectEqualStrings("intern-ai", owner.name);
    try std.testing.expect(owner.builtin);
    // 不同端点 → 无归属
    try std.testing.expect(endpointOwner(&registry, "custom-2", "https://other.example/v1") == null);
}

test "loadRegistry: 同端点条目在装载期被忽略（内置优先，早判不触网）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\[
        \\  {"name":"custom-1","baseURL":"https://discovery-api.intern-ai.org.cn/v1","apiKeyEnv":"CUSTOM_KEY"},
        \\  {"name":"amd-2","baseURL":"https://developer.amd.com.cn/radeon/api/v1/","apiKeyEnv":"AMD_RADEON_API_KEY"}
        \\]
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "providers.json", .data = text });
    const path = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}providers.json", .{
        std.testing.TmpDir.parent_dir_path, std.fs.path.sep_str, &tmp.sub_path, std.fs.path.sep_str,
    });

    var registry = try loadRegistryWith(arena, std.testing.io, path);
    defer registry.deinit();

    // 两家内置照旧；同端点条目没有注册成第二个供应商（否则裸模型 id 必然歧义）
    try std.testing.expectEqual(@as(usize, 2), registry.profiles.items.len);
    try std.testing.expect(registry.find("custom-1") == null);
    try std.testing.expect(registry.find("amd-2") == null);
    try std.testing.expect(registry.find("intern-ai") != null);
    try std.testing.expect(registry.find("amd-radeon") != null);
}
