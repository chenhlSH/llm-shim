//! 交互式命令行提示：stdin 读行 + stdout 输出（菜单与探针向导共用）。
const std = @import("std");
const Io = std.Io;

pub const Prompt = struct {
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    pub fn init(io: Io, stdin_buffer: []u8, stdout_buffer: []u8) Prompt {
        return .{
            .reader = std.Io.File.stdin().reader(io, stdin_buffer),
            .writer = std.Io.File.stdout().writer(io, stdout_buffer),
        };
    }

    pub fn print(p: *Prompt, text: []const u8) !void {
        try p.writer.interface.writeAll(text);
        try p.writer.flush();
    }

    pub fn printf(p: *Prompt, comptime fmt: []const u8, args: anytype) !void {
        try p.writer.interface.print(fmt, args);
        try p.writer.flush();
    }

    /// 打印提示并读一行。EOF 返回 null；结果指向 reader 内部缓冲区，
    /// 下一次读取即失效（需要留存请 dupe）。
    pub fn ask(p: *Prompt, text: []const u8) !?[]const u8 {
        try p.print(text);
        return try p.readLine();
    }

    /// 读一行：用 `takeDelimiter`（会消费分隔符；`takeDelimiterExclusive`
    /// 不消费，会读出空行——见交接文档 A13），并裁掉 CRLF 的 `\r`。
    pub fn readLine(p: *Prompt) !?[]const u8 {
        const line = (try p.reader.interface.takeDelimiter('\n')) orelse return null;
        return std.mem.trimEnd(u8, line, "\r");
    }
};
