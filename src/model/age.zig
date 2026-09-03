// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;

pub const AgeBody = struct {
    name: []const u8,
    icon: Icon.Id,

    pub fn validate(self: *const AgeBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const AgeCreate = AgeBody;
pub const AgeUpdate = AgeBody;

pub const AgeRow = struct {
    id: Age.Id,
    name: []const u8,
    icon: Icon.Id,
};

pub const Age = struct {
    pub const Id = u32;
    pub const Create = AgeCreate;
    pub const Update = AgeUpdate;
    pub const Row = AgeRow;
    pub const table_name: []const u8 = "ages";

    id: Id = 0,
    name: []const u8,
    icon: Icon,

    /// Builds a Age from its stored row, resolving the icon the row names by id.
    ///
    /// `db` is anything that can `readItem`; taking it as `anytype` is what lets
    /// the model own this step without importing the query layer that calls it.
    /// The strings come straight from `row`, which the caller already copied
    /// into `gpa` -- see Database.rowToT.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !Age {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
        };
    }
};

test "AgeCreate.validate accepts a well-formed age" {
    const age = AgeCreate{ .name = "Old", .icon = 1 };
    try age.validate();
}

test "AgeCreate.validate rejects an empty name" {
    const age = AgeCreate{ .name = "", .icon = 1 };
    try std.testing.expectError(error.EmptyName, age.validate());
}

test "Age serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const age = Age{ .id = 1, .name = "Old", .icon = Icon{ .id = 1, .name = "abacus" } };
    try std.json.Stringify.value(age, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"}}
    , out.written());
}
