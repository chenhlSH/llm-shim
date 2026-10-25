//! 时钟：unix 毫秒/秒（跨平台：Windows 走 ntdll，其余走 libc clock_gettime）。
const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

const windows_epoch_diff_100ns: i64 = 11_644_473_600_000_000; // 1601→1970，单位 100ns

pub fn unixMilli() i64 {
    switch (builtin.os.tag) {
        .windows => {
            const value: i64 = @intCast(std.os.windows.ntdll.RtlGetSystemTimePrecise());
            return @divTrunc(value - windows_epoch_diff_100ns, 10_000);
        },
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
        },
    }
}

pub fn unixSeconds() u64 {
    switch (builtin.os.tag) {
        .windows => return @intCast(@divTrunc(unixMilli(), 1000)),
        else => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            return @intCast(ts.sec);
        },
    }
}

/// 阻塞式毫秒睡眠（探针节流用；跨平台）。
pub fn sleepMilli(milliseconds: u64) void {
    switch (builtin.os.tag) {
        .windows => Sleep(@intCast(@min(milliseconds, std.math.maxInt(u32)))),
        else => {
            var req: std.c.timespec = .{
                .sec = @intCast(milliseconds / 1000),
                .nsec = @intCast((milliseconds % 1000) * 1_000_000),
            };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
        },
    }
}
