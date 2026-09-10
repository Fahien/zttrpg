// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;
const Database = @import("../database.zig").Database;
const Skill = @import("skill.zig").Skill;

pub const KinBody = struct {
    name: []const u8,
    icon: Icon.Id,
    movement: u32,

    // Mirrors the kins table's CHECK constraints: the database enforces
    // integrity, this gives clients a 400 instead of a 500.
    pub fn validate(self: *const KinBody) !void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.movement == 0) return error.MovementOutOfRange;
    }
};

pub const KinCreate = KinBody;
pub const KinUpdate = KinBody;

pub const KinRow = struct {
    id: Kin.Id,
    name: []const u8,
    icon: Icon.Id,
    movement: u32,
};

pub const KinSkill = struct {
    pub const table_name: []const u8 = "kin_skills";
};

pub const Kin = struct {
    pub const Id = u32;
    pub const Create = KinCreate;
    pub const Update = KinUpdate;
    pub const Row = KinRow;
    pub const table_name: []const u8 = "kins";
    pub const resource_name: []const u8 = "kin";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    /// How far a character of this kin moves before agility adds or takes: the
    /// one number a character gets from its kin rather than from its sheet.
    movement: u32,

    skills: []Skill,

    /// Builds a Kin from its stored row, resolving the icon the row names by id.
    ///
    /// The strings come straight from `row`, which the caller already copied
    /// into `gpa` -- see Database.rowToT.
    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !Kin {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;
        const skills = try db.readRelated(gpa, Kin, Skill, KinSkill, row.id);

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
            .movement = row.movement,
            .skills = skills,
        };
    }
};

test "KinCreate.validate accepts a well-formed kin" {
    const kin = KinCreate{ .name = "Elf", .icon = 1, .movement = 10 };
    try kin.validate();
}

test "KinCreate.validate rejects an empty name" {
    const kin = KinCreate{ .name = "", .icon = 1, .movement = 10 };
    try std.testing.expectError(error.EmptyName, kin.validate());
}

test "KinCreate.validate rejects a kin that cannot move" {
    // The kins table says `movement > 0`.
    const kin = KinCreate{ .name = "Elf", .icon = 1, .movement = 0 };
    try std.testing.expectError(error.MovementOutOfRange, kin.validate());
}

test "Kin serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const kin = Kin{ .id = 1, .name = "Elf", .icon = Icon{ .id = 1, .name = "abacus" }, .movement = 10, .skills = &.{} };
    try std.json.Stringify.value(kin, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"},"movement":10,"skills":[]}
    , out.written());
}
