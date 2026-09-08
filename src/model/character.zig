// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;
const Age = @import("age.zig").Age;
const Profession = @import("profession.zig").Profession;
const Kin = @import("kin.zig").Kin;
const Attribute = @import("attribute.zig").Attribute;
const Skill = @import("skill.zig").Skill;
const SkillBaseChance = @import("skill_base_chance.zig").SkillBaseChance;
const DamageBonus = @import("damage_bonus.zig").DamageBonus;

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
    /// The player's total on this attribute, not a change: a PUT carries
    /// absolute values, so sending the same body twice is harmless.
    spent: u32,

    /// Nothing to check on one element. The floor is the type, and the ceiling
    /// and the pool are configuration only the database can read, so it
    /// enforces them through the character attribute CHECK constraints.
    pub fn validate(_: *const BodyCharacterAttribute) error{}!void {}

    /// An empty body is a legal no-op: saving a sheet nobody edited.
    pub fn validateAll(items: []const BodyCharacterAttribute) BodyError!void {
        return validateBodyList(BodyCharacterAttribute, BodyCharacterAttribute.key_name, items);
    }
};

/// Flat SQL row for the character_attributes table. `value` is a generated
/// column, base + spent + modifier, read back rather than computed here so the
/// formula exists once in the database as a generated column.
pub const RowCharacterAttribute = struct {
    character: Character.Id,
    attribute: Attribute.Id,
    base: u32,
    spent: u32,
    modifier: i32,
    value: u32,
};

pub const CharacterAttribute = struct {
    pub const table_name: []const u8 = "character_attributes";
    pub const Body = BodyCharacterAttribute;
    pub const Row = RowCharacterAttribute;

    attribute: Attribute,
    base: u32,
    spent: u32,
    modifier: i32,
    value: u32,

    /// The row carries `character` as well, but the value is served as part of
    /// that character, so the id is dropped here rather than repeated.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !CharacterAttribute {
        const attribute = (try db.readItem(gpa, Attribute, row.attribute)) orelse
            return error.AttributeNotFound;

        return .{
            .attribute = attribute,
            .base = row.base,
            .spent = row.spent,
            .modifier = row.modifier,
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
    /// Derived from the character's saved attributes; null for an ability.
    base_chance: ?u32,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !CharacterSkill {
        const skill = (try db.readItem(gpa, Skill, row.skill)) orelse return error.SkillNotFound;
        const base_chance = if (skill.attribute != null) chance: {
            const attributes = try db.readSubResource(gpa, Character, CharacterAttribute, row.character);
            const bands = try db.readAllAlloc(gpa, SkillBaseChance);
            break :chance try deriveSkillBaseChance(skill, attributes, bands);
        } else null;

        return .{
            .skill = skill,
            .value = row.value,
            .base_chance = base_chance,
        };
    }
};

/// Use the governing attribute's final value, including spent points and age.
/// Null means an ability has no governing attribute. A missing sheet entry or
/// rule band is an error, since neither supplies a valid free skill level.
pub fn deriveSkillBaseChance(skill: Skill, attributes: []const CharacterAttribute, bands: []const SkillBaseChance) error{ CharacterAttributeNotFound, SkillBaseChanceNotFound }!?u32 {
    const attribute = skill.attribute orelse return null;
    for (attributes) |entry| {
        if (entry.attribute.id != attribute.id) continue;
        for (bands) |band| {
            if (entry.value >= band.min_value and entry.value <= band.max_value) {
                return band.base_chance;
            }
        }
        return error.SkillBaseChanceNotFound;
    }
    return error.CharacterAttributeNotFound;
}

/// A band of one attribute's values and what it adds to a character's
/// movement. Rows rather than code, like age_attributes: which attribute drives
/// movement, and by how much, is game data.
pub const BodyMovementModifier = struct {
    attribute: Attribute.Id,
    min_value: u32,
    max_value: u32,
    modifier: i32,

    // Mirrors the movement modifier table's CHECK constraint.
    pub fn validate(self: *const BodyMovementModifier) error{BandOutOfOrder}!void {
        if (self.min_value > self.max_value) return error.BandOutOfOrder;
    }
};

/// Flat SQL row: the attribute is an id here and a record in the model.
pub const RowMovementModifier = struct {
    id: MovementModifier.Id,
    attribute: Attribute.Id,
    min_value: u32,
    max_value: u32,
    modifier: i32,
};

pub const MovementModifier = struct {
    pub const Id = u32;
    pub const Create = BodyMovementModifier;
    pub const Update = BodyMovementModifier;
    pub const Row = RowMovementModifier;
    pub const table_name: []const u8 = "movement_modifiers";

    id: Id = 0,
    attribute: Attribute,
    min_value: u32,
    max_value: u32,
    modifier: i32,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !MovementModifier {
        const attribute = (try db.readItem(gpa, Attribute, row.attribute)) orelse
            return error.AttributeNotFound;

        return .{
            .id = row.id,
            .attribute = attribute,
            .min_value = row.min_value,
            .max_value = row.max_value,
            .modifier = row.modifier,
        };
    }
};

/// Movement is the kin's base plus every band the sheet lands in. It is derived
/// on each read and never stored, so an edited attribute is right at once and
/// there is no second copy to fall out of step with the first.
pub fn deriveMovement(base: u32, attributes: []const CharacterAttribute, bands: []const MovementModifier) i32 {
    var movement: i32 = @intCast(base);
    for (bands) |band| {
        for (attributes) |entry| {
            if (entry.attribute.id == band.attribute.id and
                entry.value >= band.min_value and entry.value <= band.max_value)
            {
                movement += band.modifier;
            }
        }
    }
    return movement;
}

pub const CharacterDamageBonus = struct {
    attribute: Attribute,
    /// One extra die with this many sides; null means no bonus.
    die_sides: ?u32,
};

/// Each configured attribute contributes one result, even below its first
/// threshold. Select by threshold, independent of row order or die size.
pub fn deriveDamageBonuses(gpa: Allocator, attributes: []const CharacterAttribute, rules: []const DamageBonus) ![]CharacterDamageBonus {
    var bonuses: std.ArrayList(CharacterDamageBonus) = .empty;
    errdefer bonuses.deinit(gpa);

    for (attributes) |entry| {
        var configured = false;
        var selected: ?DamageBonus = null;
        for (rules) |rule| {
            if (rule.attribute != entry.attribute.id) continue;
            configured = true;
            if (entry.value < rule.min_value) continue;
            if (selected == null or rule.min_value > selected.?.min_value) {
                selected = rule;
            }
        }
        if (configured) {
            try bonuses.append(gpa, .{
                .attribute = entry.attribute,
                .die_sides = if (selected) |rule| rule.die_sides else null,
            });
        }
    }
    return bonuses.toOwnedSlice(gpa);
}

/// What arrives in a request.
pub const BodyCharacter = struct {
    name: []const u8,
    level: u32,
    kin: Kin.Id,
    profession: Profession.Id,
    age: Age.Id,

    // Mirrors the characters table's CHECK constraints: the database
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
    profession: Profession.Id,
    age: Age.Id,
    attribute_points: u32,
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
    profession: Profession,
    age: Age,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !CharacterSummary {
        const kin = (try db.readItem(gpa, Kin, row.kin)) orelse return error.KinNotFound;
        const profession = (try db.readItem(gpa, Profession, row.profession)) orelse return error.ProfessionNotFound;
        const age = (try db.readItem(gpa, Age, row.age)) orelse return error.AgeNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .level = row.level,
            .kin = kin,
            .profession = profession,
            .age = age,
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
    profession: Profession,
    age: Age,
    attribute_points: u32,
    /// Derived from the kin and the sheet on every read: see deriveMovement.
    movement: i32,
    damage_bonuses: []const CharacterDamageBonus,
    attributes: []const CharacterAttribute,
    skills: []const CharacterSkill,

    /// Unlike the other models, a character is not one row: its attribute and
    /// skill values live in their own tables and are fetched here, keyed by
    /// this character's id.
    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !Character {
        const summary = try CharacterSummary.fromRow(db, gpa, row);
        const attributes = try db.readSubResource(gpa, Character, CharacterAttribute, row.id);
        const bands = try db.readAllAlloc(gpa, MovementModifier);
        const rules = try db.readAllAlloc(gpa, DamageBonus);

        return .{
            .id = summary.id,
            .name = summary.name,
            .level = summary.level,
            .kin = summary.kin,
            .profession = summary.profession,
            .age = summary.age,
            .attribute_points = row.attribute_points,
            .movement = deriveMovement(summary.kin.movement, attributes, bands),
            .damage_bonuses = try deriveDamageBonuses(gpa, attributes, rules),
            .attributes = attributes,
            .skills = try db.readSubResource(gpa, Character, CharacterSkill, row.id),
        };
    }
};

test "CreateCharacter.validate accepts a well-formed character" {
    const character = CreateCharacter{
        .name = "Grog",
        .level = 1,
        .kin = 1,
        .profession = 1,
        .age = 1,
    };
    try character.validate();
}

test "CreateCharacter.validate rejects an empty name" {
    const character = CreateCharacter{
        .name = "",
        .level = 3,
        .kin = 1,
        .profession = 1,
        .age = 1,
    };
    try std.testing.expectError(error.EmptyName, character.validate());
}

test "CreateCharacter.validate rejects levels out of range" {
    const zero = CreateCharacter{
        .name = "Grog",
        .level = 0,
        .kin = 1,
        .profession = 1,
        .age = 1,
    };
    try std.testing.expectError(error.LevelOutOfRange, zero.validate());

    const too_high = CreateCharacter{
        .name = "Grog",
        .level = 101,
        .kin = 1,
        .profession = 1,
        .age = 1,
    };
    try std.testing.expectError(error.LevelOutOfRange, too_high.validate());

    const max = CreateCharacter{
        .name = "Grog",
        .level = 100,
        .kin = 1,
        .profession = 1,
        .age = 1,
    };
    try max.validate();
}

test "Character serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const icon = Icon{ .id = 1, .name = "abacus" };
    const kin = Kin{ .id = 1, .name = "Elf", .icon = icon, .movement = 10 };
    const profession = Profession{ .id = 1, .name = "Warrior", .icon = icon, .description = "A strong melee fighter", .specializations = &.{} };
    const age = Age{ .id = 1, .name = "Old", .icon = icon, .trained_skill_count = 8 };
    const character = Character{
        .id = 1,
        .name = "Alice",
        .level = 2,
        .kin = kin,
        .profession = profession,
        .age = age,
        .attribute_points = 54,
        .movement = 10,
        .damage_bonuses = &.{},
        .attributes = &.{},
        .skills = &.{},
    };
    try std.json.Stringify.value(character, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"},"movement":10},"profession":{"id":1,"name":"Warrior","icon":{"id":1,"name":"abacus"},"description":"A strong melee fighter","specializations":[]},"age":{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"},"trained_skill_count":8},"attribute_points":54,"movement":10,"damage_bonuses":[],"attributes":[],"skills":[]}
    , out.written());
}

test "a summary is a character without its sheet" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const icon = Icon{ .id = 1, .name = "abacus" };
    const kin = Kin{ .id = 1, .name = "Elf", .icon = icon, .movement = 10 };
    const profession = Profession{ .id = 1, .name = "Warrior", .icon = icon, .description = "A strong melee fighter", .specializations = &.{} };
    const age = Age{ .id = 1, .name = "Old", .icon = icon, .trained_skill_count = 8 };
    const summary = CharacterSummary{ .id = 1, .name = "Alice", .level = 2, .kin = kin, .profession = profession, .age = age };
    try std.json.Stringify.value(summary, .{}, &out.writer);

    // The roster renders these four fields, so this is all a list has to carry.
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"},"movement":10},"profession":{"id":1,"name":"Warrior","icon":{"id":1,"name":"abacus"},"description":"A strong melee fighter","specializations":[]},"age":{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"},"trained_skill_count":8}}
    , out.written());
}

test "CreateCharacter parses from a JSON body" {
    const parsed = try std.json.parseFromSlice(
        CreateCharacter,
        std.testing.allocator,
        \\{"name":"Grog","level":3,"kin":1,"profession":1,"age":1}
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
        \\[{"attribute":1,"spent":4},{"attribute":2,"spent":0}]
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(2, parsed.value.len);
    try std.testing.expectEqual(1, parsed.value[0].attribute);
    try std.testing.expectEqual(4, parsed.value[0].spent);
    try std.testing.expectEqual(0, parsed.value[1].spent);
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
        .{ .attribute = 1, .spent = 0 },
        .{ .attribute = 2, .spent = 7 },
    });
}

test "validateAll accepts an empty body" {
    // Saving a sheet nobody edited is a no-op, not an error.
    try BodyCharacterAttribute.validateAll(&.{});
    try BodyCharacterSkill.validateAll(&.{});
}

test "validate rejects values the CHECK constraint would reject" {
    // The character skills table says `value >= 0 AND value < 1024`, so
    // 1023 is the largest legal value and 1024 must never reach Postgres.
    const highest_legal = BodyCharacterSkill{ .skill = 1, .value = 1023 };
    try highest_legal.validate();

    const one_too_many = BodyCharacterSkill{ .skill = 1, .value = 1024 };
    try std.testing.expectError(error.ValueOutOfRange, one_too_many.validate());
}

test "an attribute body has no static rule to check" {
    // The ceiling and the pool live in the configs table, which only the
    // database can read, so the character attribute constraints enforce them and a 1024 here
    // is refused there with a 400. Validation keeps the one rule Postgres
    // cannot see, a repeated key, in validateAll.
    const anything = BodyCharacterAttribute{ .attribute = 1, .spent = 1024 };
    try anything.validate();
}

test "validateAll rejects an out-of-range value anywhere in the body" {
    try std.testing.expectError(error.ValueOutOfRange, BodyCharacterSkill.validateAll(&.{
        .{ .skill = 1, .value = 3 },
        .{ .skill = 2, .value = 1024 },
    }));
}

test "validateAll rejects a repeated key" {
    // Postgres cannot catch this: two UPDATEs against the same row both
    // succeed and the last one wins. Silently accepting it would hide a
    // client bug, so it is a 400 instead.
    try std.testing.expectError(error.DuplicateEntry, BodyCharacterAttribute.validateAll(&.{
        .{ .attribute = 1, .spent = 3 },
        .{ .attribute = 1, .spent = 9 },
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
        \\[{"character":1,"attribute":1,"spent":4}]
    ,
        .{},
    ));
}

const test_agility = Attribute{ .id = 3, .name = "Agility", .icon = .{ .id = 1, .name = "abacus" }, .short = "AGL", .description = "Body control." };

/// The five agility bands from the rules.
const agility_bands = [_]MovementModifier{
    .{ .attribute = test_agility, .min_value = 1, .max_value = 6, .modifier = -4 },
    .{ .attribute = test_agility, .min_value = 7, .max_value = 9, .modifier = -2 },
    .{ .attribute = test_agility, .min_value = 10, .max_value = 12, .modifier = 0 },
    .{ .attribute = test_agility, .min_value = 13, .max_value = 15, .modifier = 2 },
    .{ .attribute = test_agility, .min_value = 16, .max_value = 18, .modifier = 4 },
};

fn sheetWithAgility(value: u32) [1]CharacterAttribute {
    return .{.{ .attribute = test_agility, .base = 3, .spent = value - 3, .modifier = 0, .value = value }};
}

test "a band's edges must be in order" {
    // The movement modifier table says `min_value <= max_value`.
    const ordered = BodyMovementModifier{ .attribute = 3, .min_value = 7, .max_value = 9, .modifier = -2 };
    try ordered.validate();

    const single = BodyMovementModifier{ .attribute = 3, .min_value = 9, .max_value = 9, .modifier = -2 };
    try single.validate();

    const inverted = BodyMovementModifier{ .attribute = 3, .min_value = 9, .max_value = 7, .modifier = -2 };
    try std.testing.expectError(error.BandOutOfOrder, inverted.validate());
}

test "movement is the kin's base plus the band agility lands in" {
    // One value per band, including both edges of the neutral one.
    try std.testing.expectEqual(6, deriveMovement(10, &sheetWithAgility(3), &agility_bands));
    try std.testing.expectEqual(6, deriveMovement(10, &sheetWithAgility(6), &agility_bands));
    try std.testing.expectEqual(8, deriveMovement(10, &sheetWithAgility(9), &agility_bands));
    try std.testing.expectEqual(10, deriveMovement(10, &sheetWithAgility(10), &agility_bands));
    try std.testing.expectEqual(10, deriveMovement(10, &sheetWithAgility(12), &agility_bands));
    try std.testing.expectEqual(12, deriveMovement(10, &sheetWithAgility(13), &agility_bands));
    try std.testing.expectEqual(14, deriveMovement(10, &sheetWithAgility(18), &agility_bands));

    // The base is the kin's: a Worgen at 12 with the same agility.
    try std.testing.expectEqual(16, deriveMovement(12, &sheetWithAgility(18), &agility_bands));
}

test "movement ignores attributes no band names, and sheets without the banded one" {
    const strength = Attribute{ .id = 1, .name = "Strength", .icon = .{ .id = 1, .name = "abacus" }, .short = "STR", .description = "Raw muscle." };
    const only_strength = [_]CharacterAttribute{
        .{ .attribute = strength, .base = 3, .spent = 15, .modifier = 0, .value = 18 },
    };
    try std.testing.expectEqual(10, deriveMovement(10, &only_strength, &agility_bands));

    // No bands at all: movement is just the kin's.
    try std.testing.expectEqual(8, deriveMovement(8, &sheetWithAgility(18), &.{}));
}

const test_strength = Attribute{ .id = 42, .name = "Strength", .icon = .{ .id = 1, .name = "abacus" }, .short = "STR", .description = "Raw muscle." };

const test_acrobatics = Skill{
    .id = 1,
    .name = "Acrobatics",
    .icon = .{ .id = 1, .name = "abacus" },
    .kind = .{ .id = 1, .name = "Core" },
    .attribute = test_agility,
    .description = "Body control.",
};

test "CharacterSkill reads the owning character's base chance alongside its saved level" {
    const TestDatabase = struct {
        skill: Skill = test_acrobatics,
        sheet: [1]CharacterAttribute = sheetWithAgility(13),
        attribute_reads: usize = 0,
        band_reads: usize = 0,

        pub fn readItem(self: *@This(), _: Allocator, comptime T: type, id: u32) !?T {
            return if (id == self.skill.id) self.skill else null;
        }

        pub fn readSubResource(self: *@This(), _: Allocator, comptime Parent: type, comptime Child: type, id: u32) ![]const Child {
            try std.testing.expectEqual(Character, Parent);
            try std.testing.expectEqual(@as(u32, 47), id);
            self.attribute_reads += 1;
            return &self.sheet;
        }

        pub fn readAllAlloc(self: *@This(), _: Allocator, comptime T: type) ![]const T {
            self.band_reads += 1;
            return &.{
                .{ .min_value = 13, .max_value = 15, .base_chance = 6 },
                .{ .min_value = 16, .max_value = 18, .base_chance = 7 },
            };
        }
    };
    var db = TestDatabase{};
    const row = RowCharacterSkill{ .character = 47, .skill = test_acrobatics.id, .value = 12 };
    const entry = try CharacterSkill.fromRow(&db, std.testing.allocator, row);
    try std.testing.expectEqual(@as(?u32, 6), entry.base_chance);
    try std.testing.expectEqual(@as(u32, 12), entry.value);

    // A new read uses the newly saved attribute, not the previous base chance.
    db.sheet = sheetWithAgility(16);
    const changed = try CharacterSkill.fromRow(&db, std.testing.allocator, row);
    try std.testing.expectEqual(@as(?u32, 7), changed.base_chance);
    try std.testing.expectEqual(@as(u32, 12), changed.value);

    // Abilities need neither the character's attributes nor the rule bands.
    db.skill.attribute = null;
    db.attribute_reads = 0;
    db.band_reads = 0;
    const ability = try CharacterSkill.fromRow(&db, std.testing.allocator, row);
    try std.testing.expect(ability.base_chance == null);
    try std.testing.expectEqual(@as(usize, 0), db.attribute_reads);
    try std.testing.expectEqual(@as(usize, 0), db.band_reads);
}

test "skill base chances match the rule data for every attribute value" {
    const parsed = try std.json.parseFromSlice(
        struct { skill_base_chances: []const SkillBaseChance },
        std.testing.allocator,
        @embedFile("../data/skill/skill-base-chances.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const bands = parsed.value.skill_base_chances;
    const expected = [_]u32{ 3, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 7, 7, 7 };
    for (expected, 1..) |chance, value| {
        const sheet = [_]CharacterAttribute{.{
            .attribute = test_agility,
            .base = 1,
            .spent = @intCast(value - 1),
            .modifier = 0,
            .value = @intCast(value),
        }};
        try std.testing.expectEqual(@as(?u32, chance), try deriveSkillBaseChance(test_acrobatics, &sheet, bands));
    }
    for ([_]u32{ 0, 19 }) |value| {
        const sheet = [_]CharacterAttribute{.{ .attribute = test_agility, .base = value, .spent = 0, .modifier = 0, .value = value }};
        try std.testing.expectError(error.SkillBaseChanceNotFound, deriveSkillBaseChance(test_acrobatics, &sheet, bands));
    }
}

test "skill base chance uses the linked attribute's final value and configured bands" {
    const sheet = [_]CharacterAttribute{
        .{ .attribute = test_strength, .base = 3, .spent = 15, .modifier = 0, .value = 18 },
        .{ .attribute = test_agility, .base = 3, .spent = 12, .modifier = -2, .value = 13 },
    };
    // Unordered bands and a custom chance ensure the result comes from data.
    const bands = [_]SkillBaseChance{
        .{ .min_value = 16, .max_value = 18, .base_chance = 7 },
        .{ .min_value = 13, .max_value = 15, .base_chance = 9 },
    };
    try std.testing.expectEqual(@as(?u32, 9), try deriveSkillBaseChance(test_acrobatics, &sheet, &bands));
}

test "an ability without an attribute has no base chance" {
    var ability = test_acrobatics;
    ability.attribute = null;
    try std.testing.expectEqual(@as(?u32, null), try deriveSkillBaseChance(ability, &.{}, &.{}));
}

test "missing skill inputs do not silently grant a base chance" {
    try std.testing.expectError(error.CharacterAttributeNotFound, deriveSkillBaseChance(test_acrobatics, &.{}, &.{}));
    const unrelated = [_]CharacterAttribute{.{ .attribute = test_strength, .base = 3, .spent = 15, .modifier = 0, .value = 18 }};
    try std.testing.expectError(error.CharacterAttributeNotFound, deriveSkillBaseChance(test_acrobatics, &unrelated, &.{}));
    try std.testing.expectError(error.SkillBaseChanceNotFound, deriveSkillBaseChance(test_acrobatics, &sheetWithAgility(13), &.{}));
}

// Deliberately unordered: neither SQL ordering nor fixed attribute ids are
// part of the calculation's contract.
const damage_rules = [_]DamageBonus{
    .{ .attribute = test_agility.id, .min_value = 17, .die_sides = 6 },
    .{ .attribute = test_strength.id, .min_value = 13, .die_sides = 4 },
    .{ .attribute = test_agility.id, .min_value = 13, .die_sides = 4 },
    .{ .attribute = test_strength.id, .min_value = 17, .die_sides = 6 },
};

test "damage bonuses include both threshold edges and have no upper limit" {
    const cases = [_]struct { value: u32, expected: ?u32 }{
        .{ .value = 0, .expected = null },
        .{ .value = 12, .expected = null },
        .{ .value = 13, .expected = 4 },
        .{ .value = 16, .expected = 4 },
        .{ .value = 17, .expected = 6 },
        .{ .value = std.math.maxInt(u32), .expected = 6 },
    };
    for ([_]Attribute{ test_strength, test_agility }) |attribute| {
        for (cases) |case| {
            const sheet = [_]CharacterAttribute{
                .{ .attribute = attribute, .base = case.value, .spent = 0, .modifier = 0, .value = case.value },
            };
            const bonuses = try deriveDamageBonuses(std.testing.allocator, &sheet, &damage_rules);
            defer std.testing.allocator.free(bonuses);
            try std.testing.expectEqual(1, bonuses.len);
            try std.testing.expectEqual(attribute.id, bonuses[0].attribute.id);
            try std.testing.expectEqual(case.expected, bonuses[0].die_sides);
        }
    }
}

test "damage bonuses use each attribute's final value independently" {
    const sheet = [_]CharacterAttribute{
        .{ .attribute = test_strength, .base = 13, .spent = 0, .modifier = -1, .value = 12 },
        .{ .attribute = test_agility, .base = 12, .spent = 4, .modifier = 1, .value = 17 },
    };
    const bonuses = try deriveDamageBonuses(std.testing.allocator, &sheet, &damage_rules);
    defer std.testing.allocator.free(bonuses);
    try std.testing.expectEqual(2, bonuses.len);
    try std.testing.expectEqual(test_strength.id, bonuses[0].attribute.id);
    try std.testing.expectEqual(null, bonuses[0].die_sides);
    try std.testing.expectEqual(test_agility.id, bonuses[1].attribute.id);
    try std.testing.expectEqual(@as(?u32, 6), bonuses[1].die_sides);

    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(bonuses, .{}, &out.writer);
    try std.testing.expectEqualStrings(
        \\[{"attribute":{"id":42,"name":"Strength","icon":{"id":1,"name":"abacus"},"short":"STR","description":"Raw muscle."},"die_sides":null},{"attribute":{"id":3,"name":"Agility","icon":{"id":1,"name":"abacus"},"short":"AGL","description":"Body control."},"die_sides":6}]
    , out.written());
}

test "the highest qualifying threshold wins even if its die is smaller" {
    const rules = [_]DamageBonus{
        .{ .attribute = test_agility.id, .min_value = 17, .die_sides = 4 },
        .{ .attribute = test_agility.id, .min_value = 13, .die_sides = 6 },
    };
    const bonuses = try deriveDamageBonuses(std.testing.allocator, &sheetWithAgility(18), &rules);
    defer std.testing.allocator.free(bonuses);
    try std.testing.expectEqual(@as(?u32, 4), bonuses[0].die_sides);
}

test "damage bonuses omit attributes without rules and rules without attributes" {
    const strength_rules = [_]DamageBonus{
        .{ .attribute = test_strength.id, .min_value = 13, .die_sides = 4 },
    };
    const unrelated = try deriveDamageBonuses(std.testing.allocator, &sheetWithAgility(18), &strength_rules);
    defer std.testing.allocator.free(unrelated);
    try std.testing.expectEqual(0, unrelated.len);

    const no_rules = try deriveDamageBonuses(std.testing.allocator, &sheetWithAgility(18), &.{});
    defer std.testing.allocator.free(no_rules);
    try std.testing.expectEqual(0, no_rules.len);

    const no_attributes = try deriveDamageBonuses(std.testing.allocator, &.{}, &damage_rules);
    defer std.testing.allocator.free(no_attributes);
    try std.testing.expectEqual(0, no_attributes.len);
}
