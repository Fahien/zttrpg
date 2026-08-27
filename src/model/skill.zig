// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;

pub const SkillKindBody = struct {
    name: []const u8,

    pub fn validate(self: *const SkillKindBody) !void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const SkillKindCreate = SkillKindBody;
pub const SkillKindUpdate = SkillKindBody;

pub const SkillKind = struct {
    pub const Create = SkillKindCreate;
    pub const Update = SkillKindUpdate;

    pub const Id = u32;
    pub const table_name: []const u8 = "skill_kinds";

    id: Id = 0,
    name: []const u8,
};

const Icon = @import("icon.zig").Icon;

pub const SkillBody = struct {
    name: []const u8,
    icon: Icon.Id,
    kind: SkillKind.Id,
    description: []const u8,

    pub fn validate(self: *const SkillBody) !void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.description.len == 0) return error.EmptyDescription;
    }
};

pub const SkillCreate = SkillBody;
pub const SkillUpdate = SkillBody;

pub const SkillRow = struct {
    id: Skill.Id,
    name: []const u8,
    icon: Icon.Id,
    kind: SkillKind.Id,
    description: []const u8,
};

pub const Skill = struct {
    pub const Id = u32;
    pub const Create = SkillCreate;
    pub const Update = SkillUpdate;
    pub const Row = SkillRow;
    pub const table_name: []const u8 = "skills";
    pub const resource_name: []const u8 = "skill";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    kind: SkillKind,
    description: []const u8,
};

test "SkillCreate.validate accepts a well-formed Skill" {
    const skill = SkillCreate{ .name = "Stealth", .icon = 1, .kind = 1, .description = "Expertise in moving unseen." };
    try skill.validate();
}

test "SkillCreate.validate rejects an empty name" {
    const skill = SkillCreate{ .name = "", .icon = 1, .kind = 1, .description = "" };
    try std.testing.expectError(error.EmptyName, skill.validate());
}

test "Skill serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const skill_kind = SkillKind{ .id = 1, .name = "Core" };

    const skill = Skill{ .id = 1, .name = "Stealth", .icon = Icon{ .id = 1, .name = "abacus" }, .kind = skill_kind, .description = "Expertise in moving unseen." };
    try std.json.Stringify.value(skill, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Stealth","icon":{"id":1,"name":"abacus"},"kind":{"id":1,"name":"Core"},"description":"Expertise in moving unseen."}
    , out.written());
}

test "SkillCreate parses from a JSON body" {
    // The shape POST /skills receives: no id, because the database assigns it.
    const parsed = try std.json.parseFromSlice(
        SkillCreate,
        std.testing.allocator,
        \\{"name":"Stealth","icon":1,"kind":1,"description":"Expertise in moving unseen."}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Stealth", parsed.value.name);
}

