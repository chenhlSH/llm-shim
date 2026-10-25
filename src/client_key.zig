//! 入站客户端携带的 API key（"key 中转"）：环境变量缺失时，把客户端请求里带的 key 透传给上游。
//!
//! 优先级（安全优先）：`apiKeyEnv` 环境变量（非空）**优先**；环境变量缺失时用入站请求携带的 key；
//! 两者都没有 → 空串（适配器据此以 `MISSING_CREDENTIAL` 快速失败，且**不重试**——那是配置问题）。
//!
//! 安全边界：网关自身的入站令牌（`AUTO_COMPAT_GATEWAY_TOKEN`）**绝不外传**——它只用于给网关鉴权，
//! 不是上游凭据。线程本地存储：网关按"每连接一线程"处理请求，进入 handler 时设置、退出时清理。
const std = @import("std");
const env = @import("env.zig");

threadlocal var current: ?[]const u8 = null;

/// 网关每请求设置；值必须活过整个请求（调用方把它 dupe 进请求 arena 后再传入）。
pub fn set(key: ?[]const u8) void {
    current = key;
}

pub fn clear() void {
    current = null;
}

pub fn get() ?[]const u8 {
    return current;
}

pub const Resolved = struct {
    key: []const u8,
    /// true = 用的是入站客户端携带的 key（环境变量缺失）；调用方据此打一行日志。
    from_client: bool = false,
};

/// 本次上游调用应使用的 key（读进程环境 + 线程本地）。
pub fn resolve(api_key_env: []const u8) Resolved {
    const env_key: ?[]const u8 = blk: {
        const raw = env.get(api_key_env) orelse break :blk null;
        break :blk if (raw.len > 0) raw else null;
    };
    return prefer(env_key, current);
}

/// 纯函数（可单测）：环境变量优先；缺失时用客户端 key；都没有 → 空串。空白环境变量视为未设置。
pub fn prefer(env_key: ?[]const u8, client_key: ?[]const u8) Resolved {
    if (env_key) |value| {
        if (value.len > 0) return .{ .key = value, .from_client = false };
    }
    if (client_key) |value| {
        if (value.len > 0) return .{ .key = value, .from_client = true };
    }
    return .{ .key = "", .from_client = false };
}

/// 纯函数（可单测）：从入站请求的两个凭据头里挑出"可中转给上游的 key"。
/// - `x-api-key`（Anthropic 客户端风格）优先；
/// - 其次 `Authorization: Bearer X`（也接受不带 Bearer 前缀的原样值）；
/// - 网关令牌（配置了 token 且与之相等）不中转；
/// - 空白值忽略。
pub fn pick(x_api_key: ?[]const u8, authorization: ?[]const u8, gateway_token: []const u8) ?[]const u8 {
    if (x_api_key) |raw| {
        const value = std.mem.trim(u8, raw, " \t");
        if (value.len > 0) return value;
    }
    const raw_auth = authorization orelse return null;
    var value = std.mem.trim(u8, raw_auth, " \t");
    // 严格剥离 "Bearer" 方案词：仅当 "Bearer" 恰好是整词（后随空格）或整值（空 token）时才剥，
    // 避免把形如 "BearerX" 的裸 key 误剥前缀。
    if (value.len == 6 and std.ascii.eqlIgnoreCase(value, "Bearer")) {
        value = "";
    } else if (value.len > 6 and std.ascii.eqlIgnoreCase(value[0..6], "Bearer") and value[6] == ' ') {
        value = std.mem.trim(u8, value[7..], " \t");
    }
    if (value.len == 0) return null;
    if (gateway_token.len > 0 and std.mem.eql(u8, value, gateway_token)) return null;
    return value;
}

test "prefer: 环境变量优先，缺失时用入站 key，空白环境变量视为未设置" {
    const from_env = prefer("sk-env", "sk-client");
    try std.testing.expectEqualStrings("sk-env", from_env.key);
    try std.testing.expect(!from_env.from_client);

    const from_client = prefer("", "sk-client");
    try std.testing.expectEqualStrings("sk-client", from_client.key);
    try std.testing.expect(from_client.from_client);

    const from_client_null_env = prefer(null, "sk-client");
    try std.testing.expectEqualStrings("sk-client", from_client_null_env.key);

    const none = prefer(null, null);
    try std.testing.expectEqualStrings("", none.key);
    try std.testing.expect(!none.from_client);
    try std.testing.expectEqualStrings("", prefer("", "").key);
}

test "pick: x-api-key 优先 / Bearer 兜底 / 网关令牌不中转" {
    try std.testing.expectEqualStrings("k1", pick("k1", null, "").?);
    try std.testing.expectEqualStrings("k1", pick("k1", "Bearer k2", "").?); // x-api-key 优先
    try std.testing.expectEqualStrings("k2", pick(null, "Bearer k2", "").?);
    try std.testing.expectEqualStrings("k3", pick(null, "k3", "").?); // 裸 Authorization 也接受
    try std.testing.expectEqualStrings("k2", pick("  ", "Bearer k2", "tok").?); // 空白值忽略
    // 网关令牌：配了 token 且与入站 Bearer 相同 → 不外传
    try std.testing.expect(pick(null, "Bearer tok", "tok") == null);
    try std.testing.expect(pick(null, "tok", "tok") == null);
    // 没配 token 时，同样的字符串只是客户端的 key → 可用
    try std.testing.expectEqualStrings("tok", pick(null, "Bearer tok", "").?);
    // 空输入
    try std.testing.expect(pick(null, null, "tok") == null);
    try std.testing.expect(pick(null, "Bearer ", "tok") == null);
    try std.testing.expect(pick("", "", "") == null);
    // 形如 "BearerX" 的裸 key（"Bearer" 后无空格）不剥前缀
    try std.testing.expectEqualStrings("BearerX-123", pick(null, "BearerX-123", "").?);
    try std.testing.expectEqualStrings("bearer-key", pick(null, "bearer-key", "").?);
}

test "resolve: 线程本地（用必定未设置的环境变量名，不碰真实 env）" {
    const unset_env_name = "AUTO_COMPAT_TEST_KEY_UNSET_XYZ";
    try std.testing.expect(env.get(unset_env_name) == null); // 前提：这个名字确实未设置
    set("sk-from-client");
    const resolved = resolve(unset_env_name);
    try std.testing.expectEqualStrings("sk-from-client", resolved.key);
    try std.testing.expect(resolved.from_client);
    clear();
    try std.testing.expectEqualStrings("", resolve(unset_env_name).key);
    try std.testing.expect(get() == null);
}
