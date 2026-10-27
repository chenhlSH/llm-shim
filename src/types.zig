//! 内部表示（IR）：与 TS 版的 GenerateOptions / StreamChunk 词汇对齐。
const std = @import("std");

pub const Effort = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,

    pub const standard_names = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" };

    pub fn parse(text: []const u8) ?Effort {
        inline for (standard_names, 0..) |candidate, index| {
            if (std.ascii.eqlIgnoreCase(text, candidate)) {
                return @enumFromInt(index);
            }
        }
        return null;
    }

    pub fn name(self: Effort) []const u8 {
        return standard_names[@intFromEnum(self)];
    }
};

pub const BlockKind = enum { text, reasoning, tool_call };

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON string, exactly as the wire carries it.
    arguments: []const u8,
};

pub const ImageRef = struct {
    /// data:... URI; bytes live in the per-request image registry.
    data_uri: []const u8,
};

pub const Block = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    image: ImageRef,
    tool_call: ToolCall,
};

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    blocks: []const Block,
};

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema object (std.json.Value).
    parameters: std.json.Value,
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    total: ?u64 = null,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    reasoning: u64 = 0,
};

pub const FinishReason = union(enum) {
    stop,
    tool_calls,
    max_tokens,
    /// Terminal failure normalized by the gateway into an error response.
    failure: struct { code: []const u8, message: []const u8 },
};

pub const Chunk = union(enum) {
    text_delta: struct { index: usize, text: []const u8 },
    reasoning_delta: struct { index: usize, text: []const u8 },
    tool_delta: struct { index: usize, id: []const u8, name: ?[]const u8, args_delta: []const u8 },
    block_end: struct { index: usize, block: Block },
    usage: Usage,
    finish: FinishReason,
    /// Cline 兼容：上游 SSE 帧顶层的 provider_metadata（原样压缩 JSON 文本）。
    /// 只有 openai 上游翻译器会产生；anthropic/responses 入站忽略（方言无此概念，
    /// Cline 的路由元数据只在 chat 形状上有意义——翻译路径上它会被丢弃）。
    provider_metadata: []const u8,
};

pub const Protocol = enum { openai, anthropic, responses };

pub const Alias = struct {
    /// Lowercase request id.
    from: []const u8,
    to: []const u8,
};

/// 档位映射策略（数据驱动，替代 TS 的闭包剖面）。
pub const EffortStrategy = enum {
    /// 原样透传（intern-ai 类）。
    passthrough,
    /// off→none，其余透传（同上，但 off 有专门拼法）。
    passthrough_off_none,
    /// AMD GLM-5.3-Flash：off/minimal→low，low/medium/high 原样，其余→high。
    glm_clamp,
    /// AMD MiMo：off→none，minimal→low，其余透传。
    mimo_map,
    /// 未知厂商：永不透传（防 400）。
    omit_always,
    /// 预设厂商：off→省略（未知 off 拼法不发），其余透传。
    passthrough_off_omit,
};

/// thinking 映射策略（anthropic 上游）。
pub const ThinkingStrategy = enum {
    /// 永不透传 thinking（未知厂商最安全默认）。
    omit,
    /// 通用预算表：off 省略，minimal 1024 / low 2048 / medium 8192 /
    /// high 16384 / xhigh 24576 / max 32768。
    generic_budgets,
};

/// 系统提示归一（"已在入口归一"的那一步）：messages 里的 system 块 → request.system。
/// 三个上游序列化器都只读 `request.system`，并且都会跳过 messages 里的 system 角色；
/// 此前只有 anthropic 入站会填 request.system，chat/responses 入站的系统提示（system 消息 /
/// instructions）因此被整个丢掉——模型收不到客户端的 agent 指令。
/// 规则：已有 request.system（anthropic 入站）不覆盖；多个 system 消息按出现顺序用空行拼接。
pub fn extractSystem(arena: std.mem.Allocator, request: GenerateRequest) !GenerateRequest {
    if (request.system != null) return request;
    var joined: std.ArrayList(u8) = .empty;
    for (request.messages) |message| {
        if (message.role != .system) continue;
        for (message.blocks) |block| {
            switch (block) {
                .text => |text| {
                    if (text.len == 0) continue;
                    if (joined.items.len > 0) try joined.appendSlice(arena, "\n\n");
                    try joined.appendSlice(arena, text);
                },
                else => {},
            }
        }
    }
    if (joined.items.len == 0) return request;
    var out = request;
    out.system = joined.items;
    return out;
}

pub const GenerateRequest = struct {
    provider: []const u8,
    model: []const u8,
    reasoning_effort: ?Effort = null,
    messages: []const Message,
    system: ?[]const u8 = null,
    tools: ?[]const ToolSchema = null,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    stop: ?[]const []const u8 = null,
    /// Cline 兼容：入站 OpenAI Chat 顶层的 providerOptions 对象（原样压缩 JSON 文本）。
    /// 仅 openai 方言上游会原样回填进请求体（"完整传给 Cline"是这套字段生效的前提）；
    /// 网关不解读其内容（only/has 的路由语义属于上游服务端），翻译路径上丢弃。
    provider_options: ?[]const u8 = null,
};

test "extractSystem: system 消息 → request.system（多段拼接/已有值不覆盖/无 system 不变）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const system_blocks = [_]Block{.{ .text = "SYS-1" }};
    const user_blocks = [_]Block{.{ .text = "hi" }};
    const messages = [_]Message{
        .{ .role = .system, .blocks = &system_blocks },
        .{ .role = .user, .blocks = &user_blocks },
    };

    const lifted = try extractSystem(arena, .{ .provider = "p", .model = "m", .messages = &messages });
    try std.testing.expectEqualStrings("SYS-1", lifted.system.?);

    // 多个 system 消息按序拼接
    const second_system = [_]Block{.{ .text = "SYS-2" }};
    const multi = [_]Message{
        .{ .role = .system, .blocks = &system_blocks },
        .{ .role = .user, .blocks = &user_blocks },
        .{ .role = .system, .blocks = &second_system },
    };
    const joined = try extractSystem(arena, .{ .provider = "p", .model = "m", .messages = &multi });
    try std.testing.expectEqualStrings("SYS-1\n\nSYS-2", joined.system.?);

    // 已有 request.system（anthropic 入站）：不覆盖
    const existing = try extractSystem(arena, .{ .provider = "p", .model = "m", .messages = &messages, .system = "KEEP" });
    try std.testing.expectEqualStrings("KEEP", existing.system.?);

    // 没有 system 消息：原样返回（system 仍为 null）
    const only_user = [_]Message{.{ .role = .user, .blocks = &user_blocks }};
    const untouched = try extractSystem(arena, .{ .provider = "p", .model = "m", .messages = &only_user });
    try std.testing.expect(untouched.system == null);

    // 空文本的 system 消息不算系统提示
    const empty_blocks = [_]Block{.{ .text = "" }};
    const empty_system = [_]Message{.{ .role = .system, .blocks = &empty_blocks }};
    const still_null = try extractSystem(arena, .{ .provider = "p", .model = "m", .messages = &empty_system });
    try std.testing.expect(still_null.system == null);
}
