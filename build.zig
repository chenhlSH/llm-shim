const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "llm-shim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // 看门狗空闲超时用 ws2_32.shutdown 打断 Windows 上的阻塞读（mingw 不默认导入 ws2_32）
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }
    // 发布构建剥离调试信息：DWARF 会把构建机的绝对路径（用户名）嵌进二进制；
    // -Dstrip=true 可显式控制，Debug 默认保留。
    exe.root_module.strip = b.option(bool, "strip", "omit debug info (default: on unless Debug)") orelse (optimize != .debug);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArg("serve"); // 跳过交互菜单，直启网关
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the gateway");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (target.result.os.tag == .windows) {
        tests.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
