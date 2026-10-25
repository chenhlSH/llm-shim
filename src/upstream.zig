//! 上游适配器聚合入口。
pub const openai = @import("upstream/openai.zig");
pub const anthropic = @import("upstream/anthropic.zig");
pub const responses = @import("upstream/responses.zig");
