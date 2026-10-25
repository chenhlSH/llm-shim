//! 闭环探针 CLI：key/URL 进 → 验证结果 + 固化 providers.json 出。
//! 作为单二进制 auto-compat 的 `probe` 模式运行，或由菜单向导（interactive）驱动。
//!
//! 参数解析是严格的（用户裁决：**只有一种显而易见写法；显式优于隐式**）：
//! - 每个选项只有一种写法：`--opt VALUE`（`--opt=VALUE` 一律拒绝并提示正确写法）；
//! - 同一选项不得重复给出——`--url` 例外：它是"可多次给出的数据项"（每个值都不同），
//!   不是同一设置的重复写法；
//! - 矛盾/冗余组合直接拒绝：`--key` 与 `--key-env` 并存、`--no-verify` 与
//!   `--verify-models`/`--verify-paid` 并存、`--verify-models 0`（跳过验证的正规写法是
//!   `--no-verify`）；
//! - 未知选项、缺失/空/类型错误的值、杂散位置参数 → exit 2 并附用法（拼错给建议）；
//! - `-h/--help`、`-V/--version` 只能单独出现：带其它参数 = "顺便帮我看用法"式的冗余写法，
//!   拒绝并给出正确指令；全部解析错误都不触网、不写文件。
const std = @import("std");
const probe = @import("probe.zig");
const providers_mod = @import("providers.zig");
const cli_io = @import("cli_io.zig");
const cli_match = @import("cli_match.zig");
const version = @import("version.zig");

pub const Options = struct {
    key_env: []const u8 = "",
    inline_key: []const u8 = "",
    urls: std.ArrayList([]const u8) = .empty,
    out_path: []const u8 = "providers.json",
    verify_models: usize = 8,
    verify_paid: bool = false,
    no_verify: bool = false,
};

pub const Outcome = enum { ok, no_key, no_match };

/// 严格解析的错误：kind + 出问题的 token + 相关选项名/近似建议。
pub const ArgError = struct {
    kind: Kind,
    arg: []const u8,
    option: []const u8 = "",
    suggestion: ?[]const u8 = null,

    pub const Kind = enum {
        unknown_option,
        unexpected_argument,
        missing_value,
        empty_value,
        invalid_value,
        /// 需要值的选项不接受值（如 `--no-verify=1`）
        unexpected_value,
        /// 冗余写法：`--opt=VALUE`（唯一写法是 `--opt VALUE`）
        redundant_spelling,
        /// 同一选项重复给出
        duplicate_option,
        /// 矛盾组合（`--no-verify` 与 `--verify-models`/`--verify-paid`）
        conflicting_options,
        /// `--key` 与 `--key-env` 并存
        both_key_sources,
        /// `--verify-models 0`（跳过验证的正规写法是 `--no-verify`）
        zero_count,
        /// help/version 带了其它参数
        info_with_arguments,
    };
};

pub const Parsed = union(enum) {
    opts: Options,
    help,
    version,
    err: ArgError,
};

/// 合法 token（含 help/version）：白名单校验 + 近似匹配建议共用。
const option_tokens = [_][]const u8{
    "--key-env",       "--key",   "--url",         "--out",
    "--verify-models", "--verify-paid", "--no-verify", "-h",
    "--help",          "-V",      "--version",
};

const help_tokens = [_][]const u8{ "-h", "--help" };
const version_tokens = [_][]const u8{ "-V", "--version" };

const probe_usage = std.fmt.comptimePrint(
    \\usage: auto-compat probe [options]  (auto-compat {s})
    \\
    \\  --key-env NAME     read the API key from environment variable NAME
    \\  --key VALUE        inline API key
    \\  --url URL          extra candidate base URL (repeatable)
    \\  --out PATH         output file (default providers.json)
    \\  --verify-models N  models to verify per provider (default 8; N >= 1)
    \\  --verify-paid      also verify paid models
    \\  --no-verify        skip model verification
    \\  -h, --help         show this help (alone)
    \\  -V, --version      print the version (alone)
    \\
    \\one spelling per option (--opt VALUE); unknown, repeated, or conflicting options are an error
    \\
, .{version.value});

/// 同一选项重复给出的检查槽（`--url` 不在此列：可多次给出的数据项）。
const Seen = struct {
    key: bool = false,
    key_env: bool = false,
    out: bool = false,
    verify_models: bool = false,
    verify_paid: bool = false,
    no_verify: bool = false,
};

fn seenSlot(seen: *Seen, name: []const u8) ?*bool {
    if (std.mem.eql(u8, name, "--key")) return &seen.key;
    if (std.mem.eql(u8, name, "--key-env")) return &seen.key_env;
    if (std.mem.eql(u8, name, "--out")) return &seen.out;
    if (std.mem.eql(u8, name, "--verify-models")) return &seen.verify_models;
    if (std.mem.eql(u8, name, "--verify-paid")) return &seen.verify_paid;
    if (std.mem.eql(u8, name, "--no-verify")) return &seen.no_verify;
    return null;
}

/// 需要值的选项（其余是布尔开关）。
fn takesValue(name: []const u8) bool {
    return std.mem.eql(u8, name, "--key-env") or std.mem.eql(u8, name, "--key") or
        std.mem.eql(u8, name, "--url") or std.mem.eql(u8, name, "--out") or
        std.mem.eql(u8, name, "--verify-models");
}

/// 严格解析 `probe` 之后的参数（不含 argv[0] 与子命令名）。内存由调用方的
/// allocator/arena 统管，返回前不做 deinit（交接文档 A5）。
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Parsed {
    // help/version 必须单独出现（顺便带参数是冗余写法：正确的指令就是它们本身）。
    for (args, 0..) |arg, arg_index| {
        const is_help = containsToken(&help_tokens, arg);
        const is_version = containsToken(&version_tokens, arg);
        if (!is_help and !is_version) continue;
        const info_option: []const u8 = if (is_help) "--help" else "--version";
        if (args.len == 1) return if (is_help) .help else .version;
        const found = if (arg_index == 0) args[1] else args[0];
        return .{ .err = .{ .kind = .info_with_arguments, .arg = found, .option = info_option } };
    }

    var opts: Options = .{};
    var seen: Seen = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (arg.len == 0 or arg[0] != '-') return .{ .err = .{ .kind = .unexpected_argument, .arg = arg } };
        // `--opt=VALUE` 是冗余写法：唯一写法是 `--opt VALUE`（不需要值的选项则直接拒绝值）。
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name_part = arg[0..eq];
            if (containsToken(&option_tokens, name_part)) {
                if (takesValue(name_part)) {
                    return .{ .err = .{ .kind = .redundant_spelling, .arg = arg, .option = name_part } };
                }
                return .{ .err = .{ .kind = .unexpected_value, .arg = arg, .option = name_part } };
            }
            return .{ .err = .{
                .kind = .unknown_option,
                .arg = arg,
                .suggestion = cli_match.suggestAmong(&option_tokens, name_part),
            } };
        }
        if (!containsToken(&option_tokens, arg)) {
            return .{ .err = .{
                .kind = .unknown_option,
                .arg = arg,
                .suggestion = cli_match.suggestAmong(&option_tokens, arg),
            } };
        }
        if (seenSlot(&seen, arg)) |slot| {
            if (slot.*) return .{ .err = .{ .kind = .duplicate_option, .arg = arg, .option = arg } };
            slot.* = true;
        }
        if (std.mem.eql(u8, arg, "--verify-paid")) {
            opts.verify_paid = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-verify")) {
            opts.no_verify = true;
            continue;
        }
        const value: []const u8 = switch (takeValue(args, &index, arg)) {
            .ok => |ok| ok,
            .err => |arg_error| return .{ .err = arg_error },
        };
        if (std.mem.eql(u8, arg, "--key-env")) {
            opts.key_env = value;
        } else if (std.mem.eql(u8, arg, "--key")) {
            opts.inline_key = value;
        } else if (std.mem.eql(u8, arg, "--url")) {
            try opts.urls.append(allocator, value);
        } else if (std.mem.eql(u8, arg, "--out")) {
            opts.out_path = value;
        } else if (std.mem.eql(u8, arg, "--verify-models")) {
            const count = parseCountValue(value) orelse
                return .{ .err = .{ .kind = .invalid_value, .arg = value, .option = arg } };
            if (count == 0) return .{ .err = .{ .kind = .zero_count, .arg = value, .option = arg } };
            opts.verify_models = count;
        }
    }

    // 顺序无关的一致性裁决：矛盾/冗余组合一律拒绝（此前是"后者/某者静默胜出"）。
    if (seen.key and seen.key_env) {
        return .{ .err = .{ .kind = .both_key_sources, .arg = "--key-env", .option = "--key" } };
    }
    if (opts.no_verify and opts.verify_paid) {
        return .{ .err = .{ .kind = .conflicting_options, .arg = "--verify-paid", .option = "--no-verify" } };
    }
    if (opts.no_verify and seen.verify_models) {
        return .{ .err = .{ .kind = .conflicting_options, .arg = "--verify-models", .option = "--no-verify" } };
    }
    return .{ .opts = opts };
}

const ValueResult = union(enum) { ok: []const u8, err: ArgError };

fn takeValue(args: []const []const u8, index: *usize, name: []const u8) ValueResult {
    if (index.* + 1 >= args.len) return .{ .err = .{ .kind = .missing_value, .arg = name, .option = name } };
    const next = args[index.* + 1];
    if (next.len == 0) return .{ .err = .{ .kind = .empty_value, .arg = name, .option = name } };
    const numeric = std.mem.eql(u8, name, "--verify-models");
    if (next[0] == '-' and !numeric) {
        // 值不能以 '-' 开头（没有"= 变体"这种第二写法可退）：直接按缺值报错。
        return .{ .err = .{ .kind = .missing_value, .arg = next, .option = name } };
    }
    index.* += 1;
    return .{ .ok = next };
}

/// 非负整数（纯十进制数字；拒绝空串/正负号/空白/小数/超界）。向导重问逻辑也用它。
pub fn parseCountValue(value: []const u8) ?usize {
    if (value.len == 0) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn containsToken(tokens: []const []const u8, value: []const u8) bool {
    for (tokens) |token| {
        if (std.mem.eql(u8, token, value)) return true;
    }
    return false;
}

/// `auto-compat probe [opts]` 入口：坏参数/无 key exit 2，无匹配 exit 1。
pub fn run(init: std.process.Init, args: []const []const u8) !void {
    switch (try parseArgs(init.arena.allocator(), args)) {
        .help => try printUsage(init, std.Io.File.stdout()),
        .version => try version.print(init.io),
        .err => |arg_error| {
            try reportArgError(init, arg_error);
            std.process.exit(2);
        },
        .opts => |opts| switch (try execute(init, opts)) {
            .ok => {},
            .no_key => std.process.exit(2),
            .no_match => std.process.exit(1),
        },
    }
}

/// 坏参数的出路（stderr + 用法）——点名 token，并给出正确指令。
fn reportArgError(init: std.process.Init, arg_error: ArgError) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(init.io, &buffer);
    const out = &writer.interface;
    switch (arg_error.kind) {
        .unknown_option => {
            try out.print("probe: unknown option: {s}\n", .{arg_error.arg});
            if (arg_error.suggestion) |suggestion| try out.print("probe: did you mean {s}?\n", .{suggestion});
        },
        .unexpected_argument => try out.print("probe: unexpected argument: {s} (probe takes options only)\n", .{arg_error.arg}),
        .missing_value => {
            if (std.mem.eql(u8, arg_error.arg, arg_error.option)) {
                try out.print("probe: missing value for {s}\n", .{arg_error.option});
            } else {
                try out.print("probe: missing value for {s} (found `{s}`; values cannot start with '-')\n", .{ arg_error.option, arg_error.arg });
            }
        },
        .empty_value => try out.print("probe: empty value for {s}\n", .{arg_error.option}),
        .invalid_value => try out.print("probe: {s} expects a non-negative integer, got: {s}\n", .{ arg_error.option, arg_error.arg }),
        .unexpected_value => try out.print("probe: {s} does not take a value\n", .{arg_error.option}),
        .redundant_spelling => try out.print("probe: {s}=VALUE is not accepted; write {s} VALUE (one spelling per option)\n", .{ arg_error.option, arg_error.option }),
        .duplicate_option => try out.print("probe: {s} given more than once (specify it once)\n", .{arg_error.option}),
        .conflicting_options => try out.print("probe: {s} and {s} contradict; keep one\n", .{ arg_error.option, arg_error.arg }),
        .both_key_sources => try out.print("probe: --key and --key-env both given; keep one (--key VALUE inline, --key-env NAME environment variable)\n", .{}),
        .zero_count => try out.print("probe: --verify-models must be at least 1; to skip model verification use --no-verify\n", .{}),
        .info_with_arguments => try out.print("probe: {s} takes no other arguments (found: {s}); run: auto-compat probe {s}\n", .{
            arg_error.option, arg_error.arg, arg_error.option,
        }),
    }
    try out.writeAll("\n");
    try out.writeAll(probe_usage);
    try writer.flush();
}

/// 菜单向导：**优先直接粘贴 API key**（回车才改用环境变量名）；
/// key 为空（或环境变量未设置）就地重问；任意一步输入 q 取消返回菜单。
/// 界面文本保持 ASCII（Windows 传统代码页下中文会乱码）。
/// 输入纪律与 CLI 一致：屏幕上标注的默认值（`[..]`）回车生效；其余写法一律重问并给出
/// 正确指令（非数字、0、非 y/n 不接受）。
pub fn interactive(init: std.process.Init, prompt: *cli_io.Prompt) !void {
    // init.arena：进程级、退出自动释放；不用 init.gpa（Debug/Safe 下是带
    // 泄漏检测的 SafeAllocator，泄漏会打噪音报告）。
    const allocator = init.arena.allocator();
    var opts: Options = .{};

    while (true) {
        const inline_raw = (try prompt.ask("probe: API key (pasted key echoes; blank = read from env var; q = cancel): ")) orelse return;
        const inline_text = std.mem.trim(u8, inline_raw, " \t");
        if (isCancel(inline_text)) return;
        if (inline_text.len > 0) {
            opts.inline_key = try allocator.dupe(u8, inline_text);
            break;
        }
        const env_raw = (try prompt.ask("probe: env var name (blank = type the key instead; q = cancel): ")) orelse return;
        const env_text = std.mem.trim(u8, env_raw, " \t");
        if (isCancel(env_text)) return;
        if (env_text.len > 0) {
            const resolved = init.environ_map.get(env_text) orelse "";
            if (resolved.len == 0) {
                try prompt.printf("probe: env var '{s}' is unset or empty; retry.\n", .{env_text});
                continue;
            }
            opts.key_env = try allocator.dupe(u8, env_text);
            break;
        }
        try prompt.print("probe: no key provided (both blank); retry: paste the key or give an env var name.\n");
    }

    const url_raw = (try prompt.ask("probe: site URL (blank = presets only; q = cancel at any step): ")) orelse return;
    if (isCancel(std.mem.trim(u8, url_raw, " \t"))) return;
    if (url_raw.len > 0) {
        try opts.urls.append(allocator, try allocator.dupe(u8, url_raw));
        try prompt.print("probe: (no request timeout; a black-hole URL may need Ctrl+C)\n");
    }

    const out_raw = (try prompt.ask("probe: out file [providers.json]: ")) orelse return;
    if (isCancel(std.mem.trim(u8, out_raw, " \t"))) return;
    if (out_raw.len > 0) opts.out_path = try allocator.dupe(u8, out_raw);

    // 非数字/0 就地重问（0 的"跳过验证"正规写法是 CLI 的 --no-verify，不在这里制造第二写法）。
    var models_raw = (try prompt.ask("probe: models to verify [8]: ")) orelse return;
    while (true) {
        const models_text = std.mem.trim(u8, models_raw, " \t");
        if (isCancel(models_text)) return;
        if (models_text.len == 0) {
            opts.verify_models = 8;
            break;
        }
        if (parseCountValue(models_text)) |models| {
            if (models >= 1) {
                opts.verify_models = models;
                break;
            }
            models_raw = (try prompt.ask("probe: give a number >= 1 (blank = 8, q = cancel; to skip verification use --no-verify on the command line): ")) orelse return;
            continue;
        }
        models_raw = (try prompt.ask("probe: not a non-negative integer; try again (blank = 8, q = cancel): ")) orelse return;
    }

    // paid 提问只接受屏幕上展示的写法：y / n / 回车取 [N]；其它输入重问。
    var paid_raw = (try prompt.ask("probe: verify paid models? [y/N]: ")) orelse return;
    while (true) {
        const paid_text = std.mem.trim(u8, paid_raw, " \t");
        if (isCancel(paid_text)) return;
        if (paid_text.len == 0 or std.ascii.eqlIgnoreCase(paid_text, "n")) {
            opts.verify_paid = false;
            break;
        }
        if (std.ascii.eqlIgnoreCase(paid_text, "y")) {
            opts.verify_paid = true;
            break;
        }
        paid_raw = (try prompt.ask("probe: answer y or n (blank = N, q = cancel): ")) orelse return;
    }

    // 到这里 key 一定非空；等价命令行不展示明文 key（inline 用占位符）。
    try prompt.printf("probe: equivalent: {s}\n\n", .{try equivalentCommand(allocator, opts)});

    _ = try execute(init, opts);
}

/// 向导回显的"等价命令行"（纯函数，便于单测）：必须与向导实际选项一致——
/// 选了 --verify-paid 就要出现，否则用户复制回显命令会跑出不一样的行为。
pub fn equivalentCommand(allocator: std.mem.Allocator, opts: Options) ![]const u8 {
    const key_part = if (opts.key_env.len > 0)
        try std.fmt.allocPrint(allocator, "--key-env {s}", .{opts.key_env})
    else
        "--key <inline>";
    const url_part = if (opts.urls.items.len > 0)
        try std.fmt.allocPrint(allocator, " --url {s}", .{opts.urls.items[0]})
    else
        "";
    const paid_part = if (opts.verify_paid) " --verify-paid" else "";
    return std.fmt.allocPrint(allocator, "auto-compat probe {s}{s} --out {s} --verify-models {d}{s}", .{
        key_part,
        url_part,
        opts.out_path,
        opts.verify_models,
        paid_part,
    });
}

fn isCancel(text: []const u8) bool {
    return std.mem.eql(u8, text, "q") or std.mem.eql(u8, text, "Q");
}

fn printUsage(init: std.process.Init, file: std.Io.File) !void {
    var buffer: [2048]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll(probe_usage);
    try writer.flush();
}

fn execute(init: std.process.Init, opts: Options) !Outcome {
    const allocator = init.arena.allocator();
    const io = init.io;

    var key: []const u8 = opts.inline_key;
    var source: []const u8 = "(inline --key)";
    if (key.len == 0 and opts.key_env.len > 0) {
        key = init.environ_map.get(opts.key_env) orelse "";
        source = opts.key_env;
    }
    if (key.len == 0) {
        if (opts.key_env.len > 0) {
            std.debug.print("probe: no key: environment variable \"{s}\" is unset or empty (export it, or pass --key VALUE).\n", .{opts.key_env});
        } else {
            std.debug.print("probe: no key. Pass --key-env NAME or --key VALUE.\n", .{});
        }
        return .no_key;
    }
    const api_key_env = if (opts.key_env.len > 0) opts.key_env else "PROBED_API_KEY";

    var extra: std.ArrayList(probe.Candidate) = .empty;
    for (opts.urls.items, 0..) |url, index| {
        const name = try std.fmt.allocPrint(allocator, "custom-{d}", .{index + 1});
        try extra.append(allocator, .{ .name = name, .base_url = url });
    }

    std.debug.print("probe {s}: trying {d} user URL(s) + {d} preset endpoints with key from {s}...\n", .{ version.value, extra.items.len, 2 + probe.PRESETS.len, source });

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const results = try probe.probeKey(allocator, &client, key, api_key_env, extra.items, .{
        .verify_models = opts.verify_models,
        .verify_paid = opts.verify_paid,
        .no_verify = opts.no_verify,
    });

    if (results.len == 0) {
        std.debug.print("probe: the key did not match any candidate endpoint (or every probe failed).\n", .{});
        return .no_match;
    }

    for (results) |result| {
        std.debug.print("\n[OK] {s}  {s}\n  protocol={s}  models={d}  verified=[{s}]  effortAccepted={s}  stoppedEarly={s}\n", .{
            result.candidate_name,
            result.base_url,
            @tagName(result.protocol),
            result.model_count,
            if (result.verified_models.len > 0) result.verified_models[0] else "-",
            if (result.effort_accepted) |accepted| (if (accepted) "true" else "false") else "n/a",
            if (result.stopped_early) "true" else "false",
        });
        if (result.stopped_early) {
            std.debug.print("  (429 circuit-breaker: verification stopped early; verified lists what was checked, the rest is undetermined)\n", .{});
        }
        if (result.protocol == .anthropic) {
            std.debug.print("  (anthropic dialect: recorded; gateway routes it via the anthropic upstream)\n", .{});
        }
    }

    // 固化：读现有 providers.json → 统一 upsert（frozen 覆盖同名条目）→ 原子写回
    const existing = std.Io.Dir.cwd().readFileAlloc(io, opts.out_path, allocator, .limited(16 * 1024 * 1024)) catch null;
    defer if (existing) |text| allocator.free(text);
    var entries: std.ArrayList(providers_mod.ProviderEntry) = .empty;
    for (results) |result| {
        try entries.append(allocator, .{
            .name = result.frozen.name,
            .base_url = result.frozen.base_url,
            .api_key_env = if (result.frozen.api_key_env.len > 0) result.frozen.api_key_env else api_key_env,
            .protocol = @fromBackingInt(@intCast(@backingInt(result.frozen.protocol))),
            .preset = result.frozen.preset,
            .verified_models = if (result.frozen.verified_models.len > 0) result.frozen.verified_models else null,
            .effort_accepted = result.frozen.effort_accepted,
        });
    }
    const merged = try providers_mod.upsertProviders(allocator, existing, entries.items);
    try providers_mod.writeTextAtomic(io, opts.out_path, merged);
    std.debug.print("\nprobe: {d} verified provider(s) frozen into {s}\n", .{ results.len, opts.out_path });
    return .ok;
}

// ---------------------------------------------------------------------------
// 测试：用户裁决"只有一种显而易见写法；显式优于隐式"固定在此。
// ---------------------------------------------------------------------------

fn parseOk(arena: std.mem.Allocator, args: []const []const u8) !Options {
    return switch (try parseArgs(arena, args)) {
        .opts => |opts| opts,
        else => error.UnexpectedParseResult,
    };
}

fn parseErr(arena: std.mem.Allocator, args: []const []const u8) !ArgError {
    return switch (try parseArgs(arena, args)) {
        .err => |arg_error| arg_error,
        else => error.UnexpectedParseResult,
    };
}

fn parseTag(arena: std.mem.Allocator, args: []const []const u8) !std.meta.Tag(Parsed) {
    return std.meta.activeTag(try parseArgs(arena, args));
}

test "parseArgs: 选项顺序无关（同一组任意排列结果一致）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const orders = [_][]const []const u8{
        &.{ "--key", "sk-1", "--url", "https://a.example", "--out", "x.json", "--verify-models", "3", "--verify-paid" },
        &.{ "--verify-paid", "--verify-models", "3", "--out", "x.json", "--url", "https://a.example", "--key", "sk-1" },
        &.{ "--url", "https://a.example", "--verify-paid", "--key", "sk-1", "--out", "x.json", "--verify-models", "3" },
    };
    for (orders) |args| {
        const opts = try parseOk(arena, args);
        try std.testing.expectEqualStrings("sk-1", opts.inline_key);
        try std.testing.expectEqualStrings("x.json", opts.out_path);
        try std.testing.expectEqual(@as(usize, 3), opts.verify_models);
        try std.testing.expect(opts.verify_paid and !opts.no_verify);
        try std.testing.expectEqual(@as(usize, 1), opts.urls.items.len);
        try std.testing.expectEqualStrings("https://a.example", opts.urls.items[0]);
    }
}

test "parseArgs: --opt=VALUE 是冗余写法，拒绝并提示正确写法" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const []const u8{
        &.{"--key=sk-1"},
        &.{"--out=x.json"},
        &.{"--url=https://a.example"},
        &.{"--key-env=K"},
        &.{"--verify-models=3"},
    }) |args| {
        const arg_error = try parseErr(arena, args);
        try std.testing.expectEqual(ArgError.Kind.redundant_spelling, arg_error.kind);
        try std.testing.expectEqualStrings(args[0][0..std.mem.indexOfScalar(u8, args[0], '=').?], arg_error.option);
    }
    // 需要值的选项与不需要值的选项都拒绝 '=' 形式
    const flag_value = try parseErr(arena, &.{"--no-verify=1"});
    try std.testing.expectEqual(ArgError.Kind.unexpected_value, flag_value.kind);
    // 未知选项带 '=' 仍按未知处理并给建议
    const unknown = try parseErr(arena, &.{"--no-verfiy=1"});
    try std.testing.expectEqual(ArgError.Kind.unknown_option, unknown.kind);
    try std.testing.expectEqualStrings("--no-verify", unknown.suggestion orelse return error.Unexpected);
}

test "parseArgs: 未知选项/杂散参数报错（不再静默忽略）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const typo = try parseErr(arena, &.{ "--no-verfiy", "--key-env", "K" });
    try std.testing.expectEqual(ArgError.Kind.unknown_option, typo.kind);
    try std.testing.expectEqualStrings("--no-verfiy", typo.arg);
    try std.testing.expectEqualStrings("--no-verify", typo.suggestion orelse return error.Unexpected);

    const unknown = try parseErr(arena, &.{"--nope"});
    try std.testing.expectEqual(ArgError.Kind.unknown_option, unknown.kind);
    try std.testing.expect(unknown.suggestion == null);

    const lower_v = try parseErr(arena, &.{"-v"});
    try std.testing.expectEqual(ArgError.Kind.unknown_option, lower_v.kind);
    try std.testing.expectEqualStrings("-V", lower_v.suggestion orelse return error.Unexpected);

    const positional = try parseErr(arena, &.{ "--key", "sk-1", "foo" });
    try std.testing.expectEqual(ArgError.Kind.unexpected_argument, positional.kind);
    try std.testing.expectEqualStrings("foo", positional.arg);
}

test "parseArgs: 值缺失/空值/类型错误" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const trailing = try parseErr(arena, &.{"--out"});
    try std.testing.expectEqual(ArgError.Kind.missing_value, trailing.kind);
    try std.testing.expectEqualStrings("--out", trailing.option);

    // 值槽里是另一个选项：按缺值报错（值不允许以 '-' 开头）
    const swallowed = try parseErr(arena, &.{ "--key", "sk-1", "--out", "--no-verify" });
    try std.testing.expectEqual(ArgError.Kind.missing_value, swallowed.kind);
    try std.testing.expectEqualStrings("--out", swallowed.option);
    try std.testing.expectEqualStrings("--no-verify", swallowed.arg);

    const empty_out = try parseErr(arena, &.{ "--out", "" });
    try std.testing.expectEqual(ArgError.Kind.empty_value, empty_out.kind);
    const empty_key = try parseErr(arena, &.{ "--key", "" });
    try std.testing.expectEqual(ArgError.Kind.empty_value, empty_key.kind);

    const abc = try parseErr(arena, &.{ "--verify-models", "abc" });
    try std.testing.expectEqual(ArgError.Kind.invalid_value, abc.kind);
    try std.testing.expectEqualStrings("--verify-models", abc.option);
    const negative = try parseErr(arena, &.{ "--verify-models", "-1" });
    try std.testing.expectEqual(ArgError.Kind.invalid_value, negative.kind);
    const decimal = try parseErr(arena, &.{ "--verify-models", "1.5" });
    try std.testing.expectEqual(ArgError.Kind.invalid_value, decimal.kind);

    // 0 是"跳过验证"的第二写法：拒绝并指向 --no-verify
    const zero = try parseErr(arena, &.{ "--verify-models", "0" });
    try std.testing.expectEqual(ArgError.Kind.zero_count, zero.kind);
}

test "parseArgs: 重复选项拒绝（--url 例外：可多次给出的数据项）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const []const u8{
        &.{ "--out", "a.json", "--out", "b.json" },
        &.{ "--key", "sk-1", "--key", "sk-2" },
        &.{ "--key-env", "A", "--key-env", "B" },
        &.{ "--verify-models", "3", "--verify-models", "5" },
        &.{ "--no-verify", "--no-verify" },
        &.{ "--verify-paid", "--verify-paid" },
    }) |args| {
        const arg_error = try parseErr(arena, args);
        try std.testing.expectEqual(ArgError.Kind.duplicate_option, arg_error.kind);
    }

    const urls = try parseOk(arena, &.{ "--key", "sk-1", "--url", "u1", "--url", "u2" });
    try std.testing.expectEqual(@as(usize, 2), urls.urls.items.len);
    try std.testing.expectEqualStrings("u1", urls.urls.items[0]);
    try std.testing.expectEqualStrings("u2", urls.urls.items[1]);
}

test "parseArgs: 矛盾/冗余组合拒绝（顺序无关）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --key 与 --key-env 并存：两种顺序都拒绝
    for ([_][]const []const u8{
        &.{ "--key", "sk-1", "--key-env", "K" },
        &.{ "--key-env", "K", "--key", "sk-1" },
    }) |args| {
        const arg_error = try parseErr(arena, args);
        try std.testing.expectEqual(ArgError.Kind.both_key_sources, arg_error.kind);
    }

    // --no-verify 与验证类选项并存：两种顺序都拒绝
    for ([_][]const []const u8{
        &.{ "--no-verify", "--verify-paid" },
        &.{ "--verify-paid", "--no-verify" },
        &.{ "--no-verify", "--verify-models", "3" },
        &.{ "--verify-models", "3", "--no-verify" },
    }) |args| {
        const arg_error = try parseErr(arena, args);
        try std.testing.expectEqual(ArgError.Kind.conflicting_options, arg_error.kind);
    }
}

test "parseArgs: help/version 只能单独出现（带其它参数 = 冗余写法，给出正确指令）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(std.meta.Tag(Parsed), .help), try parseTag(arena, &.{"--help"}));
    try std.testing.expectEqual(@as(std.meta.Tag(Parsed), .help), try parseTag(arena, &.{"-h"}));
    try std.testing.expectEqual(@as(std.meta.Tag(Parsed), .version), try parseTag(arena, &.{"--version"}));
    try std.testing.expectEqual(@as(std.meta.Tag(Parsed), .version), try parseTag(arena, &.{"-V"}));

    for ([_][]const []const u8{
        &.{ "--out", "x.json", "--help" },
        &.{ "--key", "sk-1", "-h" },
        &.{ "--out", "x.json", "--version" },
        &.{ "--key", "sk-1", "-V" },
    }) |args| {
        const arg_error = try parseErr(arena, args);
        try std.testing.expectEqual(ArgError.Kind.info_with_arguments, arg_error.kind);
    }
    const help_extra = try parseErr(arena, &.{ "--out", "x.json", "--help" });
    try std.testing.expectEqualStrings("--help", help_extra.option);
    try std.testing.expectEqualStrings("--out", help_extra.arg);
}

test "parseArgs: 默认值" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const defaults = try parseOk(arena, &.{});
    try std.testing.expectEqualStrings("", defaults.key_env);
    try std.testing.expectEqualStrings("", defaults.inline_key);
    try std.testing.expectEqualStrings("providers.json", defaults.out_path);
    try std.testing.expectEqual(@as(usize, 8), defaults.verify_models);
    try std.testing.expect(!defaults.verify_paid and !defaults.no_verify);
    try std.testing.expectEqual(@as(usize, 0), defaults.urls.items.len);
}

test "parseCountValue: 纯十进制数字" {
    try std.testing.expectEqual(@as(?usize, 0), parseCountValue("0"));
    try std.testing.expectEqual(@as(?usize, 12), parseCountValue("12"));
    try std.testing.expect(parseCountValue("") == null);
    try std.testing.expect(parseCountValue("-1") == null);
    try std.testing.expect(parseCountValue("+1") == null);
    try std.testing.expect(parseCountValue(" 1") == null);
    try std.testing.expect(parseCountValue("1.5") == null);
    try std.testing.expect(parseCountValue("abc") == null);
    try std.testing.expect(parseCountValue("99999999999999999999999") == null);
}

test "equivalentCommand: 与向导实际选项一致（含 --verify-paid）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts: Options = .{ .inline_key = "sk-1", .out_path = "out.json", .verify_models = 3 };
    const plain = try equivalentCommand(arena, opts);
    try std.testing.expectEqualStrings("auto-compat probe --key <inline> --out out.json --verify-models 3", plain);

    opts.verify_paid = true;
    const paid = try equivalentCommand(arena, opts);
    try std.testing.expect(std.mem.endsWith(u8, paid, "--verify-models 3 --verify-paid"));

    opts.key_env = "MY_KEY";
    opts.verify_paid = false;
    try opts.urls.append(arena, "https://a.example");
    const env_form = try equivalentCommand(arena, opts);
    try std.testing.expect(std.mem.indexOf(u8, env_form, "--key-env MY_KEY --url https://a.example") != null);
}