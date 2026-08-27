// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;

pub const IconBody = struct {
    name: []const u8,

    pub fn validate(self: *const IconBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const IconCreate = IconBody;
pub const IconUpdate = IconBody;

pub const Icon = struct {
    pub const Id = u32;
    pub const Create = IconCreate;
    pub const Update = IconUpdate;
    pub const table_name: []const u8 = "icons";

    id: Id = 0,
    name: []const u8,
};

test "IconCreate.validate accepts a well-formed Icon" {
    const icon = IconCreate{ .name = "abacus" };
    try icon.validate();
}

test "IconCreate.validate rejects an empty name" {
    const icon = IconCreate{ .name = "" };
    try std.testing.expectError(error.EmptyName, icon.validate());
}

test "Icon serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const icon = Icon{ .id = 1, .name = "abacus" };
    try std.json.Stringify.value(icon, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"abacus"}
    , out.written());
}
