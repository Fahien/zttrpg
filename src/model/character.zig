// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Kin = @import("kin.zig").Kin;
const Attribute = @import("attribute.zig").Attribute;
const Skill = @import("skill.zig").Skill;

pub const BodyError = error{ ValueOutOfRange, DuplicateEntry };

/// Validates a whole request body: each element on its own, plus the one rule
/// no element can check by itself. A repeated key is not a constraint
/// violation for these tables -- the UPDATE would simply run twice, last one
/// winning -- so Postgres never sees it and the check has to live here.
fn validateBodyList(comptime Body: type, comptime key: []const u8, items: []const Body) BodyError!void {
    for (items, 0..) |item, i| {
        try item.validate();

        // Bounded by the number of attributes or skills, so a scan beats a map.
        for (items[i + 1 ..]) |other| {
            if (@field(item, key) == @field(other, key)) return error.DuplicateEntry;
        }
    }
}

pub const BodyCharacterAttribute = struct {
    pub const key_name: []const u8 = Attribute.resource_name;

    attribute: Attribute.Id,
    value: u32,

    pub fn validate(self: *const BodyCharacterAttribute) error{ValueOutOfRange}!void {
        if (self.value >= 1024) return error.ValueOutOfRange;
    }

    /// An empty body is a legal no-op: saving a sheet nobody edited.
    pub fn validateAll(items: []const BodyCharacterAttribute) BodyError!void {
        return validateBodyList(BodyCharacterAttribute, BodyCharacterAttribute.key_name, items);
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

    /// The row carries `character` as well, but the value is served as part of
    /// that character, so the id is dropped here rather than repeated.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !CharacterAttribute {
        const attribute = (try db.readItem(gpa, Attribute, row.attribute)) orelse
            return error.AttributeNotFound;

        return .{
            .attribute = attribute,
            .value = row.value,
        };
    }
};

pub const BodyCharacterSkill = struct {
    pub const key_name: []const u8 = Skill.resource_name;

    skill: Skill.Id,
    value: u32,

    pub fn validate(self: *const BodyCharacterSkill) error{ValueOutOfRange}!void {
        if (self.value >= 1024) return error.ValueOutOfRange;
    }

    /// An empty body is a legal no-op: saving a sheet nobody edited.
    pub fn validateAll(items: []const BodyCharacterSkill) BodyError!void {
        return validateBodyList(BodyCharacterSkill, BodyCharacterSkill.key_name, items);
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

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !CharacterSkill {
        const skill = (try db.readItem(gpa, Skill, row.skill)) orelse return error.SkillNotFound;

        return .{
            .skill = skill,
            .value = row.value,
        };
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

/// A character without its sheet: what a roster row needs and no more.
///
/// This exists because listing every character costs one query per value on
/// every sheet, and a roster shows none of them. It is a projection for one
/// view, not a second idea of what a character is -- `Character` below stays
/// whole, and the detail page reads that.
pub const CharacterSummary = struct {
    pub const Row = RowCharacter;

    pub const table_name: []const u8 = "characters";

    id: Character.Id,
    name: []const u8,
    level: u32,
    kin: Kin,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !CharacterSummary {
        const kin = (try db.readItem(gpa, Kin, row.kin)) orelse return error.KinNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .level = row.level,
            .kin = kin,
        };
    }
};

pub const Character = struct {
    pub const Id = u32;
    pub const Create = CreateCharacter;
    pub const Update = UpdateCharacter;
    pub const Row = RowCharacter;

    /// The shape a list of characters is served as. A handler asking for many
    /// characters uses this; asking for one uses the whole thing.
    pub const Summary = CharacterSummary;

    pub const table_name: []const u8 = "characters";
    pub const resource_name: []const u8 = "character";

    id: Id,
    name: []const u8,
    level: u32,
    kin: Kin,
    attributes: []const CharacterAttribute,
    skills: []const CharacterSkill,

    /// Unlike the other models, a character is not one row: its attribute and
    /// skill values live in their own tables and are fetched here, keyed by
    /// this character's id.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !Character {
        const summary = try CharacterSummary.fromRow(db, gpa, row);

        return .{
            .id = summary.id,
            .name = summary.name,
            .level = summary.level,
            .kin = summary.kin,
            .attributes = try db.readSubResource(gpa, Character, CharacterAttribute, row.id),
            .skills = try db.readSubResource(gpa, Character, CharacterSkill, row.id),
        };
    }
};

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

test "a summary is a character without its sheet" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const kin = Kin{ .id = 1, .name = "Elf", .icon = .{ .id = 1, .name = "abacus" } };
    const summary = CharacterSummary{ .id = 1, .name = "Alice", .level = 2, .kin = kin };
    try std.json.Stringify.value(summary, .{}, &out.writer);

    // The roster renders these four fields, so this is all a list has to carry.
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"}}}
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

test "the summary is the character minus the sheet, and reads the same row" {
    // A character keeps its attributes and skills: that is what a character
    // sheet is. The summary exists so that listing characters does not have to
    // read every one of those values, and it is a projection of the same row --
    // sharing Row is what keeps the two from disagreeing about a character.
    try std.testing.expect(@hasField(Character, "attributes"));
    try std.testing.expect(@hasField(Character, "skills"));

    try std.testing.expect(!@hasField(Character.Summary, "attributes"));
    try std.testing.expect(!@hasField(Character.Summary, "skills"));

    try std.testing.expectEqual(Character.Row, Character.Summary.Row);
    try std.testing.expectEqualStrings(Character.table_name, Character.Summary.table_name);

    // Every field the summary keeps is the same field on the character.
    inline for (@typeInfo(Character.Summary).@"struct".fields) |field| {
        try std.testing.expect(@hasField(Character, field.name));
        try std.testing.expectEqual(
            @FieldType(Character, field.name),
            @FieldType(Character.Summary, field.name),
        );
    }
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

test "validateAll accepts a well-formed body" {
    try BodyCharacterAttribute.validateAll(&.{
        .{ .attribute = 1, .value = 0 },
        .{ .attribute = 2, .value = 7 },
    });
}

test "validateAll accepts an empty body" {
    // Saving a sheet nobody edited is a no-op, not an error.
    try BodyCharacterAttribute.validateAll(&.{});
    try BodyCharacterSkill.validateAll(&.{});
}

test "validate rejects values the CHECK constraint would reject" {
    // db/0060-character-attributes.sql says `value >= 0 AND value < 1024`, so
    // 1023 is the largest legal value and 1024 must never reach Postgres.
    const highest_legal = BodyCharacterAttribute{ .attribute = 1, .value = 1023 };
    try highest_legal.validate();

    const one_too_many = BodyCharacterAttribute{ .attribute = 1, .value = 1024 };
    try std.testing.expectError(error.ValueOutOfRange, one_too_many.validate());

    const skill_one_too_many = BodyCharacterSkill{ .skill = 1, .value = 1024 };
    try std.testing.expectError(error.ValueOutOfRange, skill_one_too_many.validate());
}

test "validateAll rejects an out-of-range value anywhere in the body" {
    try std.testing.expectError(error.ValueOutOfRange, BodyCharacterAttribute.validateAll(&.{
        .{ .attribute = 1, .value = 3 },
        .{ .attribute = 2, .value = 1024 },
    }));
}

test "validateAll rejects a repeated key" {
    // Postgres cannot catch this: two UPDATEs against the same row both
    // succeed and the last one wins. Silently accepting it would hide a
    // client bug, so it is a 400 instead.
    try std.testing.expectError(error.DuplicateEntry, BodyCharacterAttribute.validateAll(&.{
        .{ .attribute = 1, .value = 3 },
        .{ .attribute = 1, .value = 9 },
    }));
    try std.testing.expectError(error.DuplicateEntry, BodyCharacterSkill.validateAll(&.{
        .{ .skill = 7, .value = 3 },
        .{ .skill = 2, .value = 1 },
        .{ .skill = 7, .value = 9 },
    }));
}

test "a body element rejects unknown fields" {
    // parseFromSlice is called with .{}, so ignore_unknown_fields stays false.
    // A client sending `character` in the body gets a 400 rather than having
    // it quietly dropped.
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(
        []const BodyCharacterAttribute,
        std.testing.allocator,
        \\[{"character":1,"attribute":1,"value":4}]
    ,
        .{},
    ));
}
