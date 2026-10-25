//! 进程环境变量读取（跨平台）。
//! - POSIX：libc environ 直读（切片指向进程环境块，进程内有效）。
//! - Windows：PEB → ProcessParameters.Environment（WTF-16），
//!   首次调用构建快照 Map（键值转为 UTF-8，进程内有效）。
const std = @import("std");
const builtin = @import("builtin");

/// Windows 专用的环境快照：首次读取时惰性初始化（POSIX 直接读 environ，不用此表）。
var windows_map: ?std.process.Environ.Map = null;
var windows_map_allocator: std.mem.Allocator = undefined;
var windows_init_state = std.atomic.Value(u8).init(0); // 0=未初始化 1=初始化中 2=完成

fn ensureWindowsSnapshot() void {
    // 简单三态自旋（快照仅初始化一次；主线程启动即调用，实际无竞争）
    while (true) {
        const state = windows_init_state.load(.acquire);
        if (state == 2) return;
        if (windows_init_state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) break;
        std.Thread.yield() catch {};
    }
    windows_map_allocator = std.heap.page_allocator;
    var map = std.process.Environ.Map.init(windows_map_allocator);
    // PEB → ProcessParameters.Environment（WTF-16 块，双零结尾）
    const peb = std.os.windows.peb();
    const environment: [*:0]const u16 = @ptrCast(peb.ProcessParameters.Environment);
    const view = std.process.Environ.WindowsBlock.View{ .ptr = environment };
    map.putWindowsBlock(view) catch {};
    windows_map = map;
    windows_init_state.store(2, .release);
}

pub fn get(name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        ensureWindowsSnapshot();
        const map = &windows_map.?;
        const value = map.get(name) orelse return null;
        // Map 的值生命周期 = 进程（快照从不清理），可直接返回。
        return value;
    }
    return getPosix(name);
}

fn getPosix(name: []const u8) ?[:0]const u8 {
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const text = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        if (std.mem.eql(u8, text[0..eq], name)) {
            return text[eq + 1 .. :0];
        }
    }
    return null;
}

pub fn getOr(name: []const u8, default_value: []const u8) []const u8 {
    return get(name) orelse default_value;
}

/// 环境变量整数的纯解析结果。调用方决定无效值是"警告 + 默认"还是别的处置。
pub const IntValue = union(enum) {
    absent,
    value: u64,
    invalid,
};

/// 纯解析：未设置 → absent；空串/非数字/负号/正号/空白/超界 → invalid；
/// 只接受纯十进制数字（拒绝 "0x10"、" 5"、"+5"、"-1"）。
pub fn parseInt(raw: ?[]const u8) IntValue {
    const text = raw orelse return .absent;
    if (text.len == 0) return .invalid;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return .invalid;
    }
    const parsed = std.fmt.parseInt(u64, text, 10) catch return .invalid;
    return .{ .value = parsed };
}

test "env.parseInt: absent / 合法 / 无效" {
    try std.testing.expect(parseInt(null) == .absent);
    try std.testing.expect(parseInt("") == .invalid);
    const idle = parseInt("600000");
    try std.testing.expect(idle == .value and idle.value == 600000);
    const zero = parseInt("0");
    try std.testing.expect(zero == .value and zero.value == 0);
    try std.testing.expect(parseInt("abc") == .invalid);
    try std.testing.expect(parseInt("-1") == .invalid);
    try std.testing.expect(parseInt("+5") == .invalid);
    try std.testing.expect(parseInt(" 5") == .invalid);
    try std.testing.expect(parseInt("1.5") == .invalid);
    try std.testing.expect(parseInt("99999999999999999999999") == .invalid);
}
