//! llm-shim：LLM API 兼容屏蔽层网关 + 闭环探针（单二进制）。
//!
//! 模式分发：无参数 + TTY → 交互菜单；无参数 + 非 TTY → 网关（服务/重定向零破坏）；
//! `serve` → 网关；`probe [opts]` → 探针 CLI；`help` → 用法。
const std = @import("std");
const gateway = @import("gateway.zig");
const providers_mod = @import("providers.zig");
const env = @import("env.zig");
const probe_cli = @import("probe_cli.zig");
const cli_io = @import("cli_io.zig");
const cli_match = @import("cli_match.zig");
const router_mod = @import("router.zig");
const version = @import("version.zig");
const watchdog_mod = @import("watchdog.zig");
const placeholder_mod = @import("placeholder.zig");

const Mode = enum { menu, gateway, probe, help, version, invalid };

/// 合法子命令/顶层 token（未知命令给近似建议用）。`gateway` 不是别名：
/// 只有一种显而易见写法（`serve`），别的写法一律拒绝并给出正确指令。
const command_tokens = [_][]const u8{ "serve", "probe", "help", "version", "-h", "--help", "-V", "--version" };

const usage_text = std.fmt.comptimePrint(
    \\llm-shim {s} - LLM API compat gateway + probe (single binary)
    \\
    \\usage:
    \\  llm-shim                 interactive menu on a TTY, else gateway
    \\  llm-shim serve           run the gateway (no menu; config via env vars below)
    \\  llm-shim probe [opts]    verify an API key and freeze providers.json
    \\  llm-shim help            show this help
    \\  llm-shim version         print the version (also -V / --version)
    \\
    \\gateway environment:
    \\  AUTO_COMPAT_GATEWAY_HOST             listen host (default 127.0.0.1)
    \\  AUTO_COMPAT_GATEWAY_PORT             listen port (default 8686)
    \\  AUTO_COMPAT_GATEWAY_TOKEN inbound bearer token (empty = no auth)
    \\  AUTO_COMPAT_PROVIDERS_FILE    providers.json path (default ./providers.json)
    \\  AUTO_COMPAT_MENU              1/0 force the menu on/off
    \\  AUTO_COMPAT_PLACEHOLDER_MS    placeholder keepalive threshold (default 55000; 0 disables)
    \\  AUTO_COMPAT_IDLE_TIMEOUT_MS   upstream idle timeout (default 600000; 0 disables)
    \\
    \\probe options:
    \\  --key-env NAME     read the API key from environment variable NAME
    \\  --key VALUE        inline API key
    \\  --url URL          extra candidate base URL (repeatable)
    \\  --out PATH         output file (default providers.json)
    \\  --verify-models N  models to verify per provider (default 8)
    \\  --verify-paid      also verify paid models
    \\  --no-verify        skip model verification
    \\
, .{version.value});

const menu_text = std.fmt.comptimePrint(
    \\
    \\llm-shim {s} - LLM API compat gateway + probe (single binary)
    \\
    \\  1) gateway  listen on 127.0.0.1:8686 (OpenAI/Responses/Anthropic)
    \\  2) probe    verify an API key -> freeze providers.json
    \\  3) help     show full usage
    \\  q) quit
    \\select [1]: 
, .{version.value});

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    var rest: []const []const u8 = &.{};
    if (argv.len > 1) {
        const view = try arena.alloc([]const u8, argv.len - 1);
        for (view, argv[1..]) |*dst, src| dst.* = src;
        rest = view;
    }

    const mode: Mode = classifyArgs(rest) orelse (if (menuEnabled(init)) Mode.menu else Mode.gateway);
    switch (mode) {
        .menu => try interactiveMenu(init),
        .gateway => try serveMode(init, rest),
        .probe => try probe_cli.run(init, rest[1..]),
        .help => if (rest.len > 1) try reportInfoExtra(init, rest[0], rest[1]) else try printUsage(init.io, std.Io.File.stdout()),
        .version => if (rest.len > 1) try reportInfoExtra(init, rest[0], rest[1]) else try version.print(init.io),
        .invalid => try reportUnknownCommand(init, rest[0]),
    }
}

/// help/version 只接受单独出现（"顺便带参数"是冗余写法）：拒绝并给出正确指令。
fn reportInfoExtra(init: std.process.Init, verb: []const u8, extra: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(init.io, &buffer);
    const out = &writer.interface;
    try out.print("{s}: unexpected argument: {s}\n", .{ verb, extra });
    try out.writeAll(infoExtraHint(extra));
    try out.writeAll("\n");
    try writer.flush();
    std.process.exit(2);
}

/// 多余参数对应的"正确指令"（纯函数，便于单测）。
fn infoExtraHint(extra: []const u8) []const u8 {
    if (std.mem.eql(u8, extra, "probe")) return "to see probe options run: llm-shim probe --help";
    if (std.mem.eql(u8, extra, "serve")) return "to see gateway options run: llm-shim serve --help";
    return "help and version take no arguments; run: llm-shim help";
}

/// 未知子命令：点名 token + 正确指令（原别名/近似建议）+ 用法（stderr），exit 2。
fn reportUnknownCommand(init: std.process.Init, token: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(init.io, &buffer);
    const out = &writer.interface;
    try out.print("llm-shim {s}: unknown command: {s}\n", .{ version.value, token });
    if (std.mem.eql(u8, token, "gateway")) {
        // 曾经的别名：无别名，只有一种写法。
        try out.writeAll("llm-shim: use `serve` (no aliases): llm-shim serve\n");
    } else if (cli_match.suggestAmong(&command_tokens, token)) |suggestion| {
        try out.print("llm-shim {s}: did you mean {s}?\n", .{ version.value, suggestion });
    }
    try out.writeAll("\n");
    try writer.flush();
    try printUsage(init.io, std.Io.File.stderr());
    std.process.exit(2);
}

/// `serve`/`gateway`：网关配置只走环境变量；除 -h/--help 外的额外参数一律报错
/// （曾静默忽略：`serve --port 9000` 会让人以为端口生效了，实际仍监听 8686）。
/// serve/gateway 的参数裁决（纯函数）：空前缀 = 无参数直接进网关（非 TTY 默认模式，
/// args[0] 才是子命令名）；-h/--help 任意位置生效；其余额外参数一律拒绝并点名。
const ServeDecision = union(enum) { run, help, reject: []const u8 };

fn serveDecision(args: []const []const u8) ServeDecision {
    if (args.len == 0) return .run;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    }
    if (args.len > 1) return .{ .reject = args[1] };
    return .run;
}

fn serveMode(init: std.process.Init, args: []const []const u8) !void {
    switch (serveDecision(args)) {
        .run => try runGateway(),
        .help => try printUsage(init.io, std.Io.File.stdout()),
        .reject => |token| {
            var buffer: [512]u8 = undefined;
            var writer = std.Io.File.stderr().writer(init.io, &buffer);
            const out = &writer.interface;
            try out.print("{s}: unexpected argument: {s}\n", .{ if (args.len > 0) args[0] else "serve", token });
            try out.writeAll("gateway settings come from environment variables (AUTO_COMPAT_GATEWAY_HOST, AUTO_COMPAT_GATEWAY_PORT, AUTO_COMPAT_GATEWAY_TOKEN, AUTO_COMPAT_PROVIDERS_FILE; see: llm-shim help)\n");
            try writer.flush();
            std.process.exit(2);
        },
    }
}

/// 参数分发（args 已去掉 argv[0]）。空参数返回 null，由调用方按 TTY 规则
/// 决定菜单还是网关。命令名只有一种写法：`serve` / `probe` / `help` / `version`
/// （`-h`/`--help`/`-V`/`--version` 是各自的标准短/长形式）；别的一律拒绝。
fn classifyArgs(args: []const []const u8) ?Mode {
    if (args.len == 0) return null;
    const first = args[0];
    if (std.mem.eql(u8, first, "serve")) return .gateway;
    if (std.mem.eql(u8, first, "probe")) return .probe;
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) return .help;
    if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "--version")) return .version;
    return .invalid;
}

fn menuEnabled(init: std.process.Init) bool {
    if (init.environ_map.get("AUTO_COMPAT_MENU")) |value| {
        if (menuOverride(value)) |forced| return forced;
        // 非 1/0 的值此前被静默忽略：用户以为菜单被强制开关，实际走了 TTY 探测。
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stderr().writer(init.io, &buffer);
        writer.interface.print("[llm-shim] ignoring invalid AUTO_COMPAT_MENU=\"{s}\" (use 1 or 0); falling back to TTY detection\n", .{value}) catch {};
        writer.flush() catch {};
    }
    const stdin_tty = std.Io.File.stdin().isTty(init.io) catch false;
    if (!stdin_tty) return false;
    return std.Io.File.stdout().isTty(init.io) catch false;
}

fn menuOverride(value: ?[]const u8) ?bool {
    const text = value orelse return null;
    if (std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "0")) return false;
    return null;
}

fn interactiveMenu(init: std.process.Init) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var prompt = cli_io.Prompt.init(init.io, &stdin_buffer, &stdout_buffer);

    while (true) {
        try prompt.print(menu_text);
        const line = (try prompt.readLine()) orelse {
            try prompt.print("\n");
            return;
        };
        const choice = std.mem.trim(u8, line, " \t");
        // 只认屏幕上展示的键：1/2/3/q（q 大小写同键不算另一种写法）；回车取显示中的默认 [1]。
        if (choice.len == 0 or std.mem.eql(u8, choice, "1")) {
            try runGateway(); // 常驻，不返回
            return;
        } else if (std.mem.eql(u8, choice, "2")) {
            try probe_cli.interactive(init, &prompt);
        } else if (std.mem.eql(u8, choice, "3")) {
            try prompt.print(usage_text);
        } else if (std.mem.eql(u8, choice, "q") or std.mem.eql(u8, choice, "Q")) {
            return;
        } else {
            try prompt.print("invalid choice: use 1, 2, 3, or q\n");
        }
    }
}

fn printUsage(io: std.Io, file: std.Io.File) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(usage_text);
    try writer.flush();
}

fn runGateway() !void {
    // 常驻网关：smp_allocator 适合多线程长运行（0.17 推荐的服务器分配器）。
    const allocator = std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    warnInvalidEnv(io);
    const config: gateway.Config = .{
        .host = env.getOr("AUTO_COMPAT_GATEWAY_HOST", "127.0.0.1"),
        .port = envPort("AUTO_COMPAT_GATEWAY_PORT", 8686),
        .token = env.getOr("AUTO_COMPAT_GATEWAY_TOKEN", ""),
    };

    var registry = providers_mod.loadRegistry(allocator, io) catch |err| blk: {
        std.debug.print("[llm-shim] providers load failed ({s}), built-in providers only\n", .{@errorName(err)});
        break :blk try providers_mod.builtinRegistry(allocator);
    };
    defer registry.deinit();

    // 无效 host 直接报错退出（曾以 "error: Overflow" 之类裸错误名结束）：
    // 静默回退到别的地址（例如 0.0.0.0）会让监听位置与用户预期不符。
    const address = std.Io.net.IpAddress.parseIp4(config.host, config.port) catch {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.print("llm-shim: invalid AUTO_COMPAT_GATEWAY_HOST=\"{s}\" (need a literal IPv4 address like 127.0.0.1; see: llm-shim help)\n", .{config.host}) catch {};
        writer.flush() catch {};
        std.process.exit(2);
    };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("[llm-shim] llm-shim {s} gateway listening on http://{s}:{d}/\n", .{ version.value, config.host, config.port });
    const idle_timeout_ms = watchdog_mod.idleTimeoutMs();
    // 占位保活：CLI 启动默认开启（阈值 55s），此处注明状态（关闭方式也写清楚）。
    if (placeholder_mod.enabled()) {
        std.debug.print("[llm-shim] placeholder keepalive: ON (threshold {d}ms, streaming only; injects a disguised \"...\" during upstream silence, stripped before upstream; AUTO_COMPAT_PLACEHOLDER_MS=0 disables)\n", .{placeholder_mod.thresholdMs()});
    } else {
        std.debug.print("[llm-shim] placeholder keepalive: OFF (AUTO_COMPAT_PLACEHOLDER_MS=0)\n", .{});
    }
    if (idle_timeout_ms > 0) {
        std.debug.print("[llm-shim] upstream idle timeout: ON ({d}ms per attempt, retried by self-heal; AUTO_COMPAT_IDLE_TIMEOUT_MS=0 disables)\n", .{idle_timeout_ms});
    } else {
        std.debug.print("[llm-shim] upstream idle timeout: OFF (AUTO_COMPAT_IDLE_TIMEOUT_MS=0)\n", .{});
    }
    watchdog_mod.start(allocator, io);
    std.debug.print("[llm-shim] routes: POST /chat/completions | POST /responses | POST /messages | GET /models | GET /providers\n", .{});
    std.debug.print("[llm-shim] providers: ", .{});
    for (registry.profiles.items, 0..) |*profile, index| {
        std.debug.print("{s}{s}", .{ if (index > 0) ", " else "", profile.name });
    }
    std.debug.print("\n", .{});

    // 运行时路由/方言自愈缓存：成功路径固定后原子写回 providers.json。
    var route_cache = router_mod.Cache.init(allocator, io);
    defer route_cache.deinit();

    // 启动预热（后台，不阻塞监听）：补齐装载期没解析成功的 provider。
    if (std.Thread.spawn(.{}, router_mod.prewarm, .{ &route_cache, &registry, io })) |prewarm_thread| {
        prewarm_thread.detach();
    } else |err| {
        std.debug.print("[llm-shim] prewarm thread failed to start ({s}), skipped\n", .{@errorName(err)});
    }

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        const thread = std.Thread.spawn(.{}, gateway.handleConnection, .{ io, stream, &registry, &config, &route_cache }) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn envPort(name: []const u8, default_port: u16) u16 {
    const parsed = env.parseInt(env.get(name));
    return switch (parsed) {
        .value => |value| if (value == 0 or value > std.math.maxInt(u16)) default_port else @intCast(value),
        else => default_port,
    };
}

const IntPolicy = enum { plain, port };

/// 无效环境变量的警告文本（纯函数，便于单测）：null = 未设置或值合法。
/// port 策略额外拒绝 0 与 >65535（端口 0 = 系统随机分配，日志无法如实打印真实端口）。
fn invalidEnvNote(buffer: []u8, name: []const u8, raw: ?[]const u8, default_value: u64, policy: IntPolicy) ?[]const u8 {
    const value = switch (env.parseInt(raw)) {
        .absent => return null,
        .value => |parsed| parsed,
        .invalid => return std.fmt.bufPrint(buffer, "[llm-shim] ignoring invalid {s}=\"{s}\" (need a non-negative integer); using default {d}\n", .{
            name, raw orelse "", default_value,
        }) catch null,
    };
    if (policy == .port and (value == 0 or value > std.math.maxInt(u16))) {
        return std.fmt.bufPrint(buffer, "[llm-shim] ignoring unusable {s}={d} (port must be 1..65535); using default {d}\n", .{ name, value, default_value }) catch null;
    }
    return null;
}

/// 启动时点名无效的数值环境变量（此前静默回退：用户以为旋钮生效了，
/// 与启动日志里打印的实际值对不上也不知道为什么）。
fn warnInvalidEnv(io: std.Io) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    warnInvalidEnvOne(&writer.interface, "AUTO_COMPAT_GATEWAY_PORT", 8686, .port);
    warnInvalidEnvOne(&writer.interface, "AUTO_COMPAT_PLACEHOLDER_MS", placeholder_mod.default_threshold_ms, .plain);
    warnInvalidEnvOne(&writer.interface, watchdog_mod.idle_timeout_env, watchdog_mod.default_idle_timeout_ms, .plain);
    warnInvalidEnvOne(&writer.interface, router_mod.retry_scale_env, router_mod.default_retry_scale, .plain);
    writer.flush() catch {};
}

fn warnInvalidEnvOne(out: *std.Io.Writer, name: []const u8, default_value: u64, policy: IntPolicy) void {
    var scratch: [256]u8 = undefined;
    if (invalidEnvNote(&scratch, name, env.get(name), default_value, policy)) |note| {
        out.writeAll(note) catch {};
    }
}

test "classifyArgs dispatch" {
    try std.testing.expectEqual(@as(?Mode, null), classifyArgs(&.{}));
    try std.testing.expectEqual(@as(?Mode, .gateway), classifyArgs(&.{"serve"}));
    // `gateway` 别名已移除（只有一种写法：serve）
    try std.testing.expectEqual(@as(?Mode, .invalid), classifyArgs(&.{"gateway"}));
    try std.testing.expectEqual(@as(?Mode, .probe), classifyArgs(&.{ "probe", "--key-env", "K" }));
    try std.testing.expectEqual(@as(?Mode, .help), classifyArgs(&.{"help"}));
    try std.testing.expectEqual(@as(?Mode, .help), classifyArgs(&.{"--help"}));
    try std.testing.expectEqual(@as(?Mode, .help), classifyArgs(&.{"-h"}));
    try std.testing.expectEqual(@as(?Mode, .version), classifyArgs(&.{"version"}));
    try std.testing.expectEqual(@as(?Mode, .version), classifyArgs(&.{
        "-V",
    }));
    try std.testing.expectEqual(@as(?Mode, .version), classifyArgs(&.{"--version"}));
    try std.testing.expectEqual(@as(?Mode, .invalid), classifyArgs(&.{"--key-env"}));
    try std.testing.expectEqual(@as(?Mode, .invalid), classifyArgs(&.{"probe2"}));
}

test "版本号出现在菜单与帮助文本里（用户辨别新旧二进制）" {
    try std.testing.expect(std.mem.indexOf(u8, menu_text, version.value) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, version.value) != null);
}

test "menuOverride" {
    try std.testing.expectEqual(@as(?bool, true), menuOverride("1"));
    try std.testing.expectEqual(@as(?bool, false), menuOverride("0"));
    try std.testing.expectEqual(@as(?bool, null), menuOverride(null));
    try std.testing.expectEqual(@as(?bool, null), menuOverride("yes"));
    try std.testing.expectEqual(@as(?bool, null), menuOverride(""));
}

test "未知子命令的近似建议表" {
    try std.testing.expectEqualStrings("probe", cli_match.suggestAmong(&command_tokens, "Probe") orelse return error.Unexpected);
    try std.testing.expectEqualStrings("-V", cli_match.suggestAmong(&command_tokens, "-v") orelse return error.Unexpected);
    // gateway 已不是合法 token（别名移除）
    try std.testing.expect(cli_match.suggestAmong(&command_tokens, "gateway") == null);
}

test "infoExtraHint: 多余参数指向正确指令" {
    try std.testing.expectEqualStrings("to see probe options run: llm-shim probe --help", infoExtraHint("probe"));
    try std.testing.expectEqualStrings("to see gateway options run: llm-shim serve --help", infoExtraHint("serve"));
    try std.testing.expect(std.mem.indexOf(u8, infoExtraHint("--json"), "llm-shim help") != null);
}

test "serveDecision: 空前缀/裸 serve 进网关；help 任意位置；额外参数被点名" {
    try std.testing.expectEqual(std.meta.Tag(ServeDecision).run, std.meta.activeTag(serveDecision(&.{})));
    try std.testing.expectEqual(std.meta.Tag(ServeDecision).run, std.meta.activeTag(serveDecision(&.{"serve"})));
    try std.testing.expectEqual(std.meta.Tag(ServeDecision).run, std.meta.activeTag(serveDecision(&.{"gateway"})));
    try std.testing.expectEqual(std.meta.Tag(ServeDecision).help, std.meta.activeTag(serveDecision(&.{ "serve", "--help" })));
    try std.testing.expectEqual(std.meta.Tag(ServeDecision).help, std.meta.activeTag(serveDecision(&.{ "serve", "-h" })));
    try std.testing.expectEqual(std.meta.Tag(ServeDecision).help, std.meta.activeTag(serveDecision(&.{ "serve", "--port", "9000", "--help" })));
    switch (serveDecision(&.{ "serve", "--port", "9000" })) {
        .reject => |token| try std.testing.expectEqualStrings("--port", token),
        else => return error.Unexpected,
    }
    switch (serveDecision(&.{ "gateway", "extra" })) {
        .reject => |token| try std.testing.expectEqualStrings("extra", token),
        else => return error.Unexpected,
    }
}

test "invalidEnvNote: 未设置/合法不出声；无效点名并给出实际默认值" {
    var buffer: [256]u8 = undefined;
    try std.testing.expect(invalidEnvNote(&buffer, "X", null, 8686, .port) == null);
    try std.testing.expect(invalidEnvNote(&buffer, "X", "8686", 8686, .port) == null);
    const invalid = invalidEnvNote(&buffer, "AUTO_COMPAT_GATEWAY_PORT", "abc", 8686, .port) orelse return error.Unexpected;
    try std.testing.expect(std.mem.indexOf(u8, invalid, "AUTO_COMPAT_GATEWAY_PORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "8686") != null);
    var zero_buffer: [256]u8 = undefined;
    const zero = invalidEnvNote(&zero_buffer, "AUTO_COMPAT_GATEWAY_PORT", "0", 8686, .port) orelse return error.Unexpected;
    try std.testing.expect(std.mem.indexOf(u8, zero, "1..65535") != null);
    var overflow_buffer: [256]u8 = undefined;
    try std.testing.expect(invalidEnvNote(&overflow_buffer, "AUTO_COMPAT_GATEWAY_PORT", "70000", 8686, .port) != null);
    // 非 port 策略下 0 是合法值（旋钮关掉某个功能）
    var knob_buffer: [256]u8 = undefined;
    try std.testing.expect(invalidEnvNote(&knob_buffer, "AUTO_COMPAT_IDLE_TIMEOUT_MS", "0", 600000, .plain) == null);
}
