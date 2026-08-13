// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;

pub const SkillBody = struct {
    name: []const u8,
    icon: Icon.Id,
    description: []const u8,

    pub fn validate(self: *const SkillBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const SkillCreate = SkillBody;
pub const SkillUpdate = SkillBody;

pub const SkillRow = struct {
    id: Skill.Id,
    name: []const u8,
    icon: Icon.Id,
    description: []const u8,
};

pub const Skill = struct {
    pub const Id = u32;
    pub const Create = SkillCreate;
    pub const Update = SkillUpdate;
    pub const Row = SkillRow;
    pub const table_name: []const u8 = "skills";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    description: []const u8,

    pub fn init(gpa: Allocator, id: u32, name: []const u8, icon: Icon, description: []const u8) !Skill {
        const name_copy = try gpa.dupe(u8, name);
        const description_copy = try gpa.dupe(u8, description);
        return Skill{
            .id = id,
            .name = name_copy,
            .icon = icon,
            .description = description_copy,
        };
    }

    pub fn deinit(self: *const Skill, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
    }
};

test "SkillCreate.validate accepts a well-formed Skill" {
    const skill = SkillCreate{ .name = "Stealth", .icon = 1, .description = "Expertise in moving unseen." };
    try skill.validate();
}

test "SkillCreate.validate rejects an empty name" {
    const skill = SkillCreate{ .name = "", .icon = 1, .description = "" };
    try std.testing.expectError(error.EmptyName, skill.validate());
}

test "Skill serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const skill = Skill{ .id = 1, .name = "Stealth", .icon = Icon{ .id = 1, .name = "abacus" }, .description = "Expertise in moving unseen." };
    try std.json.Stringify.value(skill, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Stealth","icon":{"id":1,"name":"abacus"},"description":"Expertise in moving unseen."}
    , out.written());
}

test "SkillCreate parses from a JSON body" {
    // The shape POST /skills receives: no id, because the database assigns it.
    const parsed = try std.json.parseFromSlice(
        SkillCreate,
        std.testing.allocator,
        \\{"name":"Stealth","icon":1,"description":"Expertise in moving unseen."}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Stealth", parsed.value.name);
}

test "Skill.init copies the name and deinit frees it" {
    const gpa = std.testing.allocator;

    var name_buf = [_]u8{ 'H', 'e', 'a', 'l' };
    const skill = try Skill.init(gpa, 7, &name_buf, Icon{ .id = 1, .name = "abacus" }, "Expertise in moving unseen.");
    defer skill.deinit(gpa);

    // Mutating the source must not affect the copy.
    name_buf[0] = 'S';
    try std.testing.expectEqualStrings("Heal", skill.name);
    try std.testing.expectEqual(7, skill.id);
}
