//! 档位：入站归一 + 各厂商映射策略。与 TS 版 effort.zig / profiles 行为对齐。
const std = @import("std");
const types = @import("types.zig");
pub const Effort = types.Effort;

/// 入站档位归一（TS: normalizeInboundEffort）。
/// none/disabled/false→off；ultra→max；未知→medium；其余按标准表。
pub fn normalizeInbound(text: []const u8) ?Effort {
    if (Effort.parse(text)) |effort| return effort;
    if (std.ascii.eqlIgnoreCase(text, "none") or
        std.ascii.eqlIgnoreCase(text, "disabled") or
        std.ascii.eqlIgnoreCase(text, "false")) return .off;
    if (std.ascii.eqlIgnoreCase(text, "ultra")) return .max;
    return .medium;
}

/// Anthropic thinking 预算 → 档位（TS: thinkingBudgetToEffort）。
pub fn thinkingBudgetToEffort(budget: f64) Effort {
    if (budget <= 1024) return .low;
    if (budget <= 8192) return .medium;
    return .high;
}

/// 厂商档位映射。返回 null = 该参数整体省略。
pub fn mapEffort(strategy: types.EffortStrategy, model_name: []const u8, effort: Effort) ?[]const u8 {
    _ = model_name;
    return switch (strategy) {
        .passthrough => effort.name(),
        .passthrough_off_none => switch (effort) {
            .off => "none",
            else => effort.name(),
        },
        .glm_clamp => switch (effort) {
            .off, .minimal => "low",
            .low, .medium, .high => effort.name(),
            else => "high",
        },
        .mimo_map => switch (effort) {
            .off => "none",
            .minimal => "low",
            else => effort.name(),
        },
        .omit_always, .passthrough_off_omit => null,
    };
}

/// Anthropic 通用预算表（TS: genericAnthropicThinking）。off 必须省略。
pub fn anthropicBudget(effort: Effort) ?u64 {
    return switch (effort) {
        .off => null,
        .minimal => 1024,
        .low => 2048,
        .medium => 8192,
        .high => 16384,
        .xhigh => 24576,
        .max => 32768,
    };
}

test "normalizeInbound: 标准表原样，方言收敛" {
    try std.testing.expectEqual(Effort.off, normalizeInbound("OFF").?);
    try std.testing.expectEqual(Effort.high, normalizeInbound("high").?);
    try std.testing.expectEqual(Effort.off, normalizeInbound("none").?);
    try std.testing.expectEqual(Effort.off, normalizeInbound("disabled").?);
    try std.testing.expectEqual(Effort.max, normalizeInbound("ultra").?);
    try std.testing.expectEqual(Effort.medium, normalizeInbound("whatever").?);
}

test "mapEffort: intern-ai / amd glm / mimo / unknown" {
    try std.testing.expectEqualStrings("none", mapEffort(.passthrough_off_none, "glm-5.3", .off).?);
    try std.testing.expectEqualStrings("xhigh", mapEffort(.passthrough_off_none, "glm-5.3", .xhigh).?);
    try std.testing.expectEqualStrings("low", mapEffort(.glm_clamp, "GLM-5.3-Flash", .off).?);
    try std.testing.expectEqualStrings("high", mapEffort(.glm_clamp, "GLM-5.3-Flash", .xhigh).?);
    try std.testing.expectEqualStrings("medium", mapEffort(.glm_clamp, "GLM-5.3-Flash", .medium).?);
    try std.testing.expectEqualStrings("none", mapEffort(.mimo_map, "MiMo-V2.6-Flash", .off).?);
    try std.testing.expectEqualStrings("low", mapEffort(.mimo_map, "MiMo-V2.6-Flash", .minimal).?);
    try std.testing.expectEqual(null, mapEffort(.omit_always, "any", .high));
}

test "anthropicBudget: off 省略" {
    try std.testing.expectEqual(@as(?u64, null), anthropicBudget(.off));
    try std.testing.expectEqual(@as(?u64, 16384), anthropicBudget(.high));
}
