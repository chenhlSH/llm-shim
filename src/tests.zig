//! 测试聚合入口。
comptime {
    _ = @import("types.zig");
    _ = @import("env.zig");
    _ = @import("cli_match.zig");
    _ = @import("placeholder.zig");
    _ = @import("client_key.zig");
    _ = @import("version.zig");
    _ = @import("watchdog.zig");
    _ = @import("effort.zig");
    _ = @import("http_util.zig");
    _ = @import("providers.zig");
    _ = @import("images.zig");
    _ = @import("upstream.zig");
    _ = @import("inbound.zig");
    // 六个方言适配器必须显式导入：仅在聚合器里 pub const re-export 不会收集其 test
    // （Zig 只分析被引用的声明；曾因此让 5/6 个方言测试整轮未跑——2026-10-14 修复）。
    _ = @import("inbound/openai.zig");
    _ = @import("inbound/anthropic.zig");
    _ = @import("inbound/responses.zig");
    _ = @import("upstream/openai.zig");
    _ = @import("upstream/anthropic.zig");
    _ = @import("upstream/responses.zig");
    _ = @import("gateway.zig");
    _ = @import("main.zig");
    _ = @import("probe_cli.zig");
    _ = @import("probe.zig");
    _ = @import("router.zig");
}
