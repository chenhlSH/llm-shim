//! HTTP / SSE 工具：SSE 帧解析、/vN 前缀剥离、timing-safe 比较。
const std = @import("std");

/// SSE 帧读取器：把上游字节流按"空行分隔"切成事件帧，
/// 每帧把所有 `data:` 行的载荷拼接为一段 data（容忍任意 event 名）。
pub const SseFrame = struct {
    data: []const u8,
};

pub const SseParser = struct {
    /// 从 reader 取下一个帧；流正常结束返回 null。
    pub fn next(
        reader: *std.Io.Reader,
        allocator: std.mem.Allocator,
    ) !?SseFrame {
        var saw_event = false;
        var data_lines: std.ArrayList(u8) = .empty;
        defer data_lines.deinit(allocator);
        var saw_any = false;

        while (true) {
            const line_raw = reader.takeDelimiter('\n') catch |err| switch (err) {
                else => |e| return e,
            } orelse {
                // 干净 EOF
                if (!saw_any and data_lines.items.len == 0) return null;
                break;
            };
            saw_any = true;
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) {
                if (data_lines.items.len > 0 or saw_event) break;
                continue;
            }
            if (std.mem.startsWith(u8, line, ":")) continue; // 注释/心跳
            if (std.mem.startsWith(u8, line, "data:")) {
                const payload = std.mem.trimStart(u8, line["data:".len..], " ");
                if (data_lines.items.len > 0) data_lines.append(allocator, '\n') catch return error.OutOfMemory;
                data_lines.appendSlice(allocator, payload) catch return error.OutOfMemory;
            } else if (std.mem.startsWith(u8, line, "event:")) {
                // 事件名不进帧：上游方言的事件类型在 data JSON 的 type 字段里读取。
                saw_event = true;
            }
        }
        return SseFrame{ .data = try allocator.dupe(u8, data_lines.items) };
    }
};

/// 剥离一个可选的 /vN 版本段（TS: server.ts 的 versionMatch）。
/// `/v1/chat/completions`→`/chat/completions`；`/chat/completions`→原样。
pub fn stripVersionPrefix(raw_path: []const u8) []const u8 {
    if (raw_path.len < 2) return raw_path;
    if (raw_path[0] != '/') return raw_path;
    if (raw_path[1] != 'v') return raw_path;
    var index: usize = 2;
    if (index >= raw_path.len or !std.ascii.isDigit(raw_path[index])) return raw_path;
    while (index < raw_path.len and std.ascii.isDigit(raw_path[index])) index += 1;
    if (index < raw_path.len and raw_path[index] == '/') {
        return raw_path[index..];
    }
    if (index == raw_path.len) return "/";
    return raw_path;
}

/// 把流式响应的两级缓冲都推到 socket。
/// `BodyWriter.writer` 是先攒帧、满 16KB 才 drain 的缓冲；`BodyWriter.flush()`
/// 只 flush 外层的连接写缓冲。只调前者会让所有 SSE 帧滞留到响应结束（保活帧
/// 因此永远到不了客户端），必须两级都 flush。
pub fn flushBody(body: *std.http.BodyWriter) !void {
    try body.writer.flush();
    try body.flush();
}

/// timing-safe 字符串比较。
pub fn timingSafeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| diff |= byte_a ^ byte_b;
    return diff == 0;
}

test "stripVersionPrefix" {
    try std.testing.expectEqualStrings("/chat/completions", stripVersionPrefix("/v1/chat/completions"));
    try std.testing.expectEqualStrings("/chat/completions", stripVersionPrefix("/v2/chat/completions"));
    try std.testing.expectEqualStrings("/chat/completions", stripVersionPrefix("/v99/chat/completions"));
    try std.testing.expectEqualStrings("/models", stripVersionPrefix("/v1/models"));
    try std.testing.expectEqualStrings("/", stripVersionPrefix("/v1"));
    try std.testing.expectEqualStrings("/chat/completions", stripVersionPrefix("/chat/completions"));
    try std.testing.expectEqualStrings("/", stripVersionPrefix("/"));
}

test "timingSafeEqual" {
    try std.testing.expect(timingSafeEqual("abc", "abc"));
    try std.testing.expect(!timingSafeEqual("abc", "abd"));
    try std.testing.expect(!timingSafeEqual("abc", "abcd"));
}

test "SseParser: 基本帧 + event 名 + 多 data 行" {
    const input = "event: done\ndata: [DONE]\n\n" ++
        "data: {\"a\":1}\ndata: {\"b\":2}\n\n" ++
        ": heartbeat\n\ndata: last\n";
    var input_reader: std.Io.Reader = .fixed(input);

    const frame1 = try SseParser.next(&input_reader, std.testing.allocator);
    try std.testing.expect(frame1 != null);
    try std.testing.expectEqualStrings("[DONE]", frame1.?.data);
    std.testing.allocator.free(frame1.?.data);

    const frame2 = try SseParser.next(&input_reader, std.testing.allocator);
    try std.testing.expect(frame2 != null);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}", frame2.?.data);
    std.testing.allocator.free(frame2.?.data);

    const frame3 = try SseParser.next(&input_reader, std.testing.allocator);
    try std.testing.expect(frame3 != null);
    try std.testing.expectEqualStrings("last", frame3.?.data);
    std.testing.allocator.free(frame3.?.data);

    const frame4 = try SseParser.next(&input_reader, std.testing.allocator);
    try std.testing.expect(frame4 == null);
}
