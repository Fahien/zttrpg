// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Kin = @import("kin.zig").Kin;
const Attribute = @import("attribute.zig").Attribute;
const Skill = @import("skill.zig").Skill;

pub const BodyCharacterAttribute = struct {
    attribute: Attribute.Id,
    value: u32,

    pub fn validate(self: *const BodyCharacterAttribute) error{ValueOutOfRange}!void {
        if (self.value > 1024) return error.ValueOutOfRange;
    }
};

/// Flat SQL row for the character_attributes table.
pub const RowCharacterAttribute = struct {
    character: Character.Id,
    attribute: Attribute.Id,
    value: u32,
};

pub const CharacterAttribute = struct {
    pub const table_name: []const u8 = "character_attributes";
    pub const Body = BodyCharacterAttribute;
    pub const Row = RowCharacterAttribute;

    attribute: Attribute,
    value: u32,

    pub fn deinit(self: *const CharacterAttribute, gpa: Allocator) void {
        self.attribute.deinit(gpa);
    }
};

pub const BodyCharacterSkill = struct {
    skill: Skill.Id,
    value: u32,

    pub fn validate(self: *const BodyCharacterSkill) error{ValueOutOfRange}!void {
        if (self.value > 1024) return error.ValueOutOfRange;
    }
};

/// Flat SQL row for the character_skills table.
pub const RowCharacterSkill = struct {
    character: Character.Id,
    skill: Skill.Id,
    value: u32,
};

pub const CharacterSkill = struct {
    pub const table_name: []const u8 = "character_skills";
    pub const Body = BodyCharacterSkill;
    pub const Row = RowCharacterSkill;

    skill: Skill,
    value: u32,

    pub fn deinit(self: *const CharacterSkill, gpa: Allocator) void {
        self.skill.deinit(gpa);
    }
};

/// What arrives in a request.
pub const BodyCharacter = struct {
    name: []const u8,
    level: u32,
    kin: Kin.Id,

    // Mirrors the CHECK constraints in db/0001-characters.sql: the database
    // enforces integrity, this gives clients a 400 instead of a 500.
    pub fn validate(self: *const BodyCharacter) error{ EmptyName, LevelOutOfRange }!void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.level < 1 or self.level > 100) return error.LevelOutOfRange;
    }
};

pub const CreateCharacter = BodyCharacter;
pub const UpdateCharacter = BodyCharacter;
pub const RowCharacter = struct {
    id: Character.Id,
    name: []const u8,
    level: u32,
    kin: Kin.Id,
};

pub const Character = struct {
    pub const Id = u32;
    pub const Create = CreateCharacter;
    pub const Update = UpdateCharacter;
    pub const Row = RowCharacter;

    pub const table_name: []const u8 = "characters";
    pub const resource_name: []const u8 = "character";

    id: Id,
    name: []const u8,
    level: u32,
    kin: Kin,
    attributes: []const CharacterAttribute,
    skills: []const CharacterSkill,

    pub fn init(
        gpa: Allocator,
        id: u32,
        name: []const u8,
        level: u32,
        kin: Kin,
        attributes: []const CharacterAttribute,
        skills: []const CharacterSkill,
    ) !Character {
        const name_copy = try gpa.dupe(u8, name);

        return Character{
            .id = id,
            .name = name_copy,
            .level = level,
            .kin = kin,
            .attributes = attributes,
            .skills = skills,
        };
    }

    pub fn deinit(self: *const Character, gpa: Allocator) void {
        gpa.free(self.name);

        for (self.attributes) |*attr| {
            attr.deinit(gpa);
        }
        gpa.free(self.attributes);

        for (self.skills) |*skill| {
            skill.deinit(gpa);
        }
        gpa.free(self.skills);
    }
};

test "Character.init copies the name and deinit frees it" {
    const gpa = std.testing.allocator;

    var name_buf = [_]u8{ 'G', 'r', 'o', 'g' };
    const kin = Kin{ .id = 1, .name = "Elf", .icon = .{ .id = 1, .name = "abacus" } };
    const character = try Character.init(gpa, 7, &name_buf, 3, kin, &.{}, &.{});
    defer character.deinit(gpa);

    // Mutating the source must not affect the copy.
    name_buf[0] = 'F';
    try std.testing.expectEqualStrings("Grog", character.name);
    try std.testing.expectEqual(7, character.id);
    try std.testing.expectEqual(3, character.level);
}

test "CreateCharacter.validate accepts a well-formed character" {
    const character = CreateCharacter{ .name = "Grog", .level = 1, .kin = 1 };
    try character.validate();
}

test "CreateCharacter.validate rejects an empty name" {
    const character = CreateCharacter{ .name = "", .level = 3, .kin = 1 };
    try std.testing.expectError(error.EmptyName, character.validate());
}

test "CreateCharacter.validate rejects levels out of range" {
    const zero = CreateCharacter{ .name = "Grog", .level = 0, .kin = 1 };
    try std.testing.expectError(error.LevelOutOfRange, zero.validate());

    const too_high = CreateCharacter{ .name = "Grog", .level = 101, .kin = 1 };
    try std.testing.expectError(error.LevelOutOfRange, too_high.validate());

    const max = CreateCharacter{ .name = "Grog", .level = 100, .kin = 1 };
    try max.validate();
}

test "Character serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const kin = Kin{ .id = 1, .name = "Elf", .icon = .{ .id = 1, .name = "abacus" } };
    const character = Character{ .id = 1, .name = "Alice", .level = 2, .kin = kin, .attributes = &.{}, .skills = &.{} };
    try std.json.Stringify.value(character, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"}},"attributes":[],"skills":[]}
    , out.written());
}

test "CreateCharacter parses from a JSON body" {
    const parsed = try std.json.parseFromSlice(
        CreateCharacter,
        std.testing.allocator,
        \\{"name":"Grog","level":3,"kin":1}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Grog", parsed.value.name);
    try std.testing.expectEqual(3, parsed.value.level);
}

test "sub-resources name the type their request body parses into" {
    // The write handler is generic over the child type, so it reaches the body
    // shape through this decl rather than naming each struct itself.
    try std.testing.expectEqual(BodyCharacterAttribute, CharacterAttribute.Body);
    try std.testing.expectEqual(BodyCharacterSkill, CharacterSkill.Body);
}

test "BodyCharacterAttribute parses from a JSON array" {
    const parsed = try std.json.parseFromSlice(
        []const BodyCharacterAttribute,
        std.testing.allocator,
        \\[{"attribute":1,"value":4},{"attribute":2,"value":0}]
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(2, parsed.value.len);
    try std.testing.expectEqual(1, parsed.value[0].attribute);
    try std.testing.expectEqual(4, parsed.value[0].value);
    try std.testing.expectEqual(0, parsed.value[1].value);
}

test "BodyCharacterSkill parses from a JSON array" {
    const parsed = try std.json.parseFromSlice(
        []const BodyCharacterSkill,
        std.testing.allocator,
        \\[{"skill":7,"value":3}]
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(1, parsed.value.len);
    try std.testing.expectEqual(7, parsed.value[0].skill);
    try std.testing.expectEqual(3, parsed.value[0].value);
}

test "a request body carries no character id: the URL already named it" {
    // RowCharacterAttribute is the body plus `character`. Keeping identity out
    // of the body means the two can never disagree.
    try std.testing.expect(@hasField(RowCharacterAttribute, "character"));
    try std.testing.expect(!@hasField(BodyCharacterAttribute, "character"));
    try std.testing.expect(!@hasField(BodyCharacterSkill, "character"));
}
