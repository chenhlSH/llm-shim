//! 入站方言聚合入口。
pub const openai = @import("inbound/openai.zig");
pub const anthropic = @import("inbound/anthropic.zig");
pub const responses = @import("inbound/responses.zig");
