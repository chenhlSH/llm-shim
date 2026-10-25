//! 版本号（0.x；规则：日常修复只递增补丁位 x；开源发布等里程碑动 minor）。
//! 单独成模块便于 main/probe_cli/gateway 共用，也便于单测锁定格式。
const std = @import("std");

pub const value = "0.2.0";

/// 上游 User-Agent：`llm-shim/<版本>`（由运行时版本推导，避免写死漂移）。
pub fn userAgent() []const u8 {
    return "llm-shim/" ++ value;
}

/// `llm-shim version|--version|-V`：只打版本号（stdout，exit 0），
/// 便于脚本与用户核对新旧构建；main 与 probe 共用同一实现。
pub fn print(io: std.Io) !void {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.print("llm-shim {s}\n", .{value});
    try writer.flush();
}

test "version: 0.x 格式（开源里程碑可动 minor）" {
    var parts = std.mem.splitScalar(u8, value, '.');
    const major = parts.next() orelse return error.Unexpected;
    const minor = parts.next() orelse return error.Unexpected;
    const patch = parts.next() orelse return error.Unexpected;
    try std.testing.expect(parts.next() == null);
    try std.testing.expectEqual(@as(u64, 0), try std.fmt.parseInt(u64, major, 10));
    try std.testing.expect(try std.fmt.parseInt(u64, minor, 10) >= 1);
    _ = try std.fmt.parseInt(u64, patch, 10); // 补丁位必须是数字（x 递增，不回退/不带后缀）
}

test "userAgent: 与运行时版本一致" {
    try std.testing.expectEqualStrings("llm-shim/0.2.0", userAgent());
}