//! 请求级诊断：线程本地请求 id + 统一前缀日志。
//! 目的：并发/重试交错时把日志按请求对齐（客户端一次 turn ↔ 网关多行）。
//! id 优先采用客户端的 `x-request-id`（截断 32 字节、仅保留可见 ASCII），否则用进程内自增 `rN`。
//! 前缀保持 ASCII，Windows 传统代码页下不乱码。
const std = @import("std");

var next_id = std.atomic.Value(u64).init(1);
threadlocal var current: ?[]const u8 = null;

/// 开始一个请求的诊断上下文（内存由调用方 arena 统管）。
pub fn begin(allocator: std.mem.Allocator, client_id: ?[]const u8) ![]const u8 {
    const buffer = try allocator.alloc(u8, 32);
    var len: usize = 0;
    if (client_id) |raw| {
        for (raw) |byte| {
            if (len >= buffer.len) break;
            if (byte >= 0x21 and byte <= 0x7e) {
                buffer[len] = byte;
                len += 1;
            }
        }
    }
    if (len == 0) {
        const number = next_id.fetchAdd(1, .monotonic);
        const text = try std.fmt.bufPrint(buffer, "r{d}", .{number});
        len = text.len;
    }
    current = buffer[0..len];
    return current.?;
}

pub fn clear() void {
    current = null;
}

pub fn id() []const u8 {
    return current orelse "-";
}

/// 统一前缀：`[llm-shim] #<id> ...`；无请求上下文（后台线程）时退化为原前缀。
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (current) |request_id| {
        std.debug.print("[llm-shim] #{s} " ++ fmt, .{request_id} ++ args);
    } else {
        std.debug.print("[llm-shim] " ++ fmt, args);
    }
}

/// 摘要文本：控制字符压成空格、限长，避免上游错误正文刷屏或破坏单行日志。
pub fn snippet(buffer: []u8, text: []const u8, limit: usize) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        if (len >= limit or len >= buffer.len) break;
        buffer[len] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        len += 1;
    }
    return buffer[0..len];
}

test "diag: 请求 id（客户端 id 清洗 / 自增 / clear）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const client = try begin(arena, "abc-123\t\x7fXYZ");
    try std.testing.expectEqualStrings("abc-123XYZ", client);
    try std.testing.expectEqualStrings("abc-123XYZ", id());
    clear();
    try std.testing.expectEqualStrings("-", id());

    const first = try begin(arena, null);
    try std.testing.expect(std.mem.startsWith(u8, first, "r"));
    const second = try begin(arena, null);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    clear();

    // 空白/超长客户端 id 被丢弃或截断
    const padded = try begin(arena, "  ");
    try std.testing.expect(std.mem.startsWith(u8, padded, "r"));
    clear();
    const long = try begin(arena, "0123456789012345678901234567890123456789");
    try std.testing.expectEqual(@as(usize, 32), long.len);
    clear();
}

test "diag: snippet 压平控制字符并限长" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a b c", snippet(&buffer, "a\nb\tc", 16));
    try std.testing.expectEqualStrings("abcde", snippet(&buffer, "abcdefgh", 5));
}