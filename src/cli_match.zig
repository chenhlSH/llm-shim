//! 命令行近似匹配：给拼错的选项/子命令一个 "did you mean X?" 建议。
//! 纯函数（无 IO），供 main（子命令）与 probe_cli（probe 选项）共用。
const std = @import("std");

/// 编辑距离 ≤ budget 时返回距离（大小写不敏感：`-v` 与 `-V` 视为距离 0），否则 null。
/// 长度上限 64（选项名远小于此）；越界直接判不匹配。
pub fn editDistanceAtMost(a: []const u8, b: []const u8, budget: usize) ?usize {
    if (a.len > 64 or b.len > 64) return null;
    var prev: [65]usize = undefined;
    var curr: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    const distance = prev[b.len];
    return if (distance <= budget) distance else null;
}

/// 在候选表里找最接近的（距离最小且 ≤2，大小写不敏感）；并列取先出现的。
/// 纯横线 token（"-"/"--"）与空串不猜（没有有意义的建议）。
pub fn suggestAmong(candidates: []const []const u8, arg: []const u8) ?[]const u8 {
    if (std.mem.trimStart(u8, arg, "-").len == 0) return null;
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const distance = editDistanceAtMost(arg, candidate, 2) orelse continue;
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

test "editDistanceAtMost: 大小写不敏感与预算上限" {
    try std.testing.expectEqual(@as(?usize, 0), editDistanceAtMost("-V", "-v", 2));
    try std.testing.expectEqual(@as(?usize, 2), editDistanceAtMost("--no-verfiy", "--no-verify", 2));
    try std.testing.expectEqual(@as(?usize, null), editDistanceAtMost("--nope", "--no-verify", 2));
    try std.testing.expectEqual(@as(?usize, 1), editDistanceAtMost("--outt", "--out", 2));
}

test "suggestAmong: 选最近的候选，找不到返回 null" {
    const options = [_][]const u8{ "--key-env", "--key", "--out", "--no-verify" };
    try std.testing.expectEqualStrings("--key-env", suggestAmong(&options, "--key-en") orelse return error.Unexpected);
    try std.testing.expectEqualStrings("--no-verify", suggestAmong(&options, "--no-verfiy") orelse return error.Unexpected);
    try std.testing.expect(suggestAmong(&options, "--zzz") == null);
    try std.testing.expect(suggestAmong(&options, "") == null);
    try std.testing.expect(suggestAmong(&options, "-") == null);
    try std.testing.expect(suggestAmong(&options, "--") == null);

    const commands = [_][]const u8{ "serve", "gateway", "probe", "help", "version", "-h", "--help", "-V", "--version" };
    try std.testing.expectEqualStrings("probe", suggestAmong(&commands, "Probe") orelse return error.Unexpected);
    try std.testing.expectEqualStrings("-V", suggestAmong(&commands, "-v") orelse return error.Unexpected);
}