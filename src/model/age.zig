// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Attribute = @import("attribute.zig").Attribute;
const Icon = @import("icon.zig").Icon;
const Database = @import("../database.zig").Database;

pub const AgeBody = struct {
    name: []const u8,
    icon: Icon.Id,
    trained_skill_count: u32,

    pub fn validate(self: *const AgeBody) !void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.trained_skill_count != 8 and self.trained_skill_count != 10 and self.trained_skill_count != 12) {
            return error.InvalidTrainedSkillCount;
        }
    }
};

pub const AgeCreate = AgeBody;
pub const AgeUpdate = AgeBody;

pub const AgeRow = struct {
    id: Age.Id,
    name: []const u8,
    icon: Icon.Id,
    trained_skill_count: u32,
};

/// What one age does to one attribute. Rows rather than code, like the
/// movement bands: which ages adjust which attributes is game data.
///
/// Stored exactly as read, so there is no Row and nothing to hydrate. An age
/// says nothing about most attributes, and those simply have no row.
pub const AgeAttribute = struct {
    pub const table_name: []const u8 = "age_attributes";
    pub const order_by: []const u8 = "attribute";

    age: Age.Id,
    attribute: Attribute.Id,
    modifier: i32,
};

pub const Age = struct {
    pub const Id = u32;
    pub const Create = AgeCreate;
    pub const Update = AgeUpdate;
    pub const Row = AgeRow;
    pub const table_name: []const u8 = "ages";
    pub const resource_name: []const u8 = "age";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    trained_skill_count: u32,

    /// Builds a Age from its stored row, resolving the icon the row names by id.
    ///
    /// The strings come straight from `row`, which the caller already copied
    /// into `gpa` -- see Database.rowToT.
    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !Age {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
            .trained_skill_count = row.trained_skill_count,
        };
    }
};

test "AgeCreate.validate accepts a well-formed age" {
    const age = AgeCreate{ .name = "Old", .icon = 1, .trained_skill_count = 12 };
    try age.validate();
}

test "AgeCreate.validate rejects an empty name" {
    const age = AgeCreate{ .name = "", .icon = 1, .trained_skill_count = 12 };
    try std.testing.expectError(error.EmptyName, age.validate());
}
test "AgeCreate.validate rejects a trained skill count outside the three age rules" {
    const age = AgeCreate{ .name = "Old", .icon = 1, .trained_skill_count = 0 };
    try std.testing.expectError(error.InvalidTrainedSkillCount, age.validate());

    const unsupported = AgeCreate{ .name = "Old", .icon = 1, .trained_skill_count = 9 };
    try std.testing.expectError(error.InvalidTrainedSkillCount, unsupported.validate());
}

test "Age serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const age = Age{ .id = 1, .name = "Old", .icon = Icon{ .id = 1, .name = "abacus" }, .trained_skill_count = 12 };
    try std.json.Stringify.value(age, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"},"trained_skill_count":12}
    , out.written());
}
