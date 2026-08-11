// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const SkillBody = struct {
    name: []const u8,

    pub fn validate(self: *const SkillBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const SkillCreate = SkillBody;
pub const SkillUpdate = SkillBody;

pub const Skill = struct {
    pub const Id = u32;
    pub const Create = SkillCreate;
    pub const Update = SkillUpdate;
    pub const table_name: []const u8 = "skills";

    id: Id = 0,
    name: []const u8,

    pub fn init(gpa: Allocator, id: u32, name: []const u8) !Skill {
        const name_copy = try gpa.dupe(u8, name);
        return Skill{
            .id = id,
            .name = name_copy,
        };
    }

    pub fn deinit(self: *const Skill, gpa: Allocator) void {
        gpa.free(self.name);
    }
};

test "SkillCreate.validate accepts a well-formed Skill" {
    const skill = SkillCreate{ .name = "Stealth" };
    try skill.validate();
}

test "SkillCreate.validate rejects an empty name" {
    const skill = SkillCreate{ .name = "" };
    try std.testing.expectError(error.EmptyName, skill.validate());
}

test "Skill serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const skill = Skill{ .id = 1, .name = "Stealth" };
    try std.json.Stringify.value(skill, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Stealth"}
    , out.written());
}
