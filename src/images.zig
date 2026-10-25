//! 请求级图片注册表：入站的 data URI / URL 图片存为合成 gwimg- 引用，
//! 上游适配器经同一读取口取回字节。请求结束即释放。
//!
//! 【保留但当前不参与运行时】唯一保留理由：将来对接宿主附件服务
//! （TS: attachments.readImageRequest / storeImageSource）或做图片换存时可直接启用。
//! 现状：图片走 data URI 直传上游（README「与 TS 版的差异」），生产代码不引用本模块。
const std = @import("std");
const clock = @import("clock.zig");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    counter: usize = 0,

    pub const Entry = struct {
        bytes: []u8,
        media_type: []const u8,
    };

    pub const StoredImage = struct {
        attachment_id: []const u8,
        media_type: []const u8,
        byte_len: usize,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .entries = .init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.bytes);
            self.allocator.free(entry.value_ptr.media_type);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// 解析 data URI 并入表；返回合成 attachment id。
    pub fn storeDataUri(self: *Registry, data_uri: []const u8) !StoredImage {
        const marker = "base64,";
        const semicolon = std.mem.indexOf(u8, data_uri, ";") orelse return error.UnsupportedImage;
        if (!std.mem.startsWith(u8, data_uri[semicolon..], ";base64,") and
            std.mem.indexOf(u8, data_uri, marker) == null) return error.UnsupportedImage;
        const base64_start = std.mem.indexOf(u8, data_uri, marker) orelse return error.UnsupportedImage;
        const media_type = data_uri["data:".len..semicolon];
        const encoded = data_uri[base64_start + marker.len ..];
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(encoded) catch return error.UnsupportedImage;
        const bytes = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(bytes);
        decoder.decode(bytes, encoded) catch {
            self.allocator.free(bytes);
            return error.UnsupportedImage;
        };
        return self.store(media_type, bytes);
    }

    fn store(self: *Registry, media_type: []const u8, bytes: []u8) !StoredImage {
        const id = try std.fmt.allocPrint(self.allocator, "gwimg-{d}-{d}", .{ self.counter, clock.unixMilli() });
        self.counter += 1;
        const owned_media = try self.allocator.dupe(u8, media_type);
        try self.entries.put(id, .{ .bytes = bytes, .media_type = owned_media });
        return .{ .attachment_id = id, .media_type = owned_media, .byte_len = bytes.len };
    }

    pub fn peek(self: *Registry, attachment_id: []const u8) ?Entry {
        return self.entries.get(attachment_id);
    }
};

test "Registry: data URI 存取与释放" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const stored = try registry.storeDataUri("data:image/png;base64,AQID");
    try std.testing.expect(stored.attachment_id.len > 0);
    try std.testing.expectEqualStrings("image/png", stored.media_type);
    const entry = registry.peek(stored.attachment_id).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, entry.bytes);
}
