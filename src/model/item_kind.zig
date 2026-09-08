// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;

pub const ItemKindBody = struct {
    name: []const u8,
    icon: Icon.Id,

    pub fn validate(self: *const ItemKindBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const ItemKindCreate = ItemKindBody;
pub const ItemKindUpdate = ItemKindBody;

pub const ItemKindRow = struct {
    id: ItemKind.Id,
    name: []const u8,
    icon: Icon.Id,
};

pub const ItemKind = struct {
    pub const Id = u32;
    pub const Create = ItemKindCreate;
    pub const Update = ItemKindUpdate;
    pub const Row = ItemKindRow;
    pub const table_name: []const u8 = "item_kinds";

    id: Id = 0,
    name: []const u8,
    icon: Icon,

    /// Builds a ItemKind from its stored row, resolving the icon the row names by id.
    ///
    /// `db` is anything that can `readItem`; taking it as `anytype` is what lets
    /// the model own this step without importing the query layer that calls it.
    /// The strings come straight from `row`, which the caller already copied
    /// into `gpa` -- see Database.rowToT.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !ItemKind {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
        };
    }
};

test "ItemKindCreate.validate accepts a well-formed item" {
    const item = ItemKindCreate{ .name = "Old", .icon = 1 };
    try item.validate();
}

test "ItemKindCreate.validate rejects an empty name" {
    const item = ItemKindCreate{ .name = "", .icon = 1 };
    try std.testing.expectError(error.EmptyName, item.validate());
}

test "ItemKind serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const item = ItemKind{ .id = 1, .name = "Old", .icon = Icon{ .id = 1, .name = "abacus" } };
    try std.json.Stringify.value(item, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"}}
    , out.written());
}
