// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;

pub const KinBody = struct {
    name: []const u8,
    icon: Icon.Id,

    pub fn validate(self: *const KinBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const KinCreate = KinBody;
pub const KinUpdate = KinBody;

pub const KinRow = struct {
    id: Kin.Id,
    name: []const u8,
    icon: Icon.Id,
};

pub const Kin = struct {
    pub const Id = u32;
    pub const Create = KinCreate;
    pub const Update = KinUpdate;
    pub const Row = KinRow;
    pub const table_name: []const u8 = "kins";

    id: Id = 0,
    name: []const u8,
    icon: Icon,

    /// Builds a Kin from its stored row, resolving the icon the row names by id.
    ///
    /// `db` is anything that can `readItem`; taking it as `anytype` is what lets
    /// the model own this step without importing the query layer that calls it.
    /// The strings come straight from `row`, which the caller already copied
    /// into `gpa` -- see Database.rowToT.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !Kin {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
        };
    }
};

test "KinCreate.validate accepts a well-formed kin" {
    const kin = KinCreate{ .name = "Elf", .icon = 1 };
    try kin.validate();
}

test "KinCreate.validate rejects an empty name" {
    const kin = KinCreate{ .name = "", .icon = 1 };
    try std.testing.expectError(error.EmptyName, kin.validate());
}

test "Kin serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const kin = Kin{ .id = 1, .name = "Elf", .icon = Icon{ .id = 1, .name = "abacus" } };
    try std.json.Stringify.value(kin, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"}}
    , out.written());
}
