// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;
const Age = @import("age.zig").Age;
const AgeAttribute = @import("age.zig").AgeAttribute;
const Profession = @import("profession.zig").Profession;
const Specialization = @import("profession.zig").Specialization;
const Kin = @import("kin.zig").Kin;
const Attribute = @import("attribute.zig").Attribute;
const Skill = @import("skill.zig").Skill;
const SkillBaseChance = @import("skill_base_chance.zig").SkillBaseChance;
const DamageBonus = @import("damage_bonus.zig").DamageBonus;
const Config = @import("config.zig").Config;
const Database = @import("../database.zig").Database;

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

    /// Every base-chance skill is a reading of its governing attribute, so the
    /// stored values follow the attributes that moved. Before the pool is
    /// empty the sheet is a draft the browser is still previewing, and the
    /// zeroes left in the table are what say so.
    pub fn afterUpdate(db: *const Database, gpa: Allocator, character_id: Character.Id) !void {
        const pools = (try db.readProjection(gpa, Character, CreationPools, character_id)) orelse
            return error.ItemNotFound;
        if (pools.attribute_points != 0) return;

        const attributes = try db.readSubResource(gpa, Character, CharacterAttribute, character_id);
        const bands = try db.readAllAlloc(gpa, SkillBaseChance);
        const entries = try db.readSubResource(gpa, Character, CharacterSkill, character_id);

        var changed = std.ArrayList(BodyCharacterSkill).empty;
        for (entries) |entry| {
            const value = (try deriveStartingSkillValue(entry, attributes, bands)) orelse continue;
            if (value == entry.value) continue;

            try changed.append(gpa, .{ .skill = entry.skill.id, .value = value });
        }

        try db.updateSubRows(gpa, Character, CharacterSkill, CharacterSkill.Body, character_id, changed.items);
    }

    /// The row carries `character` as well, but the value is served as part of
    /// that character, so the id is dropped here rather than repeated.
    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !CharacterAttribute {
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
    trained: bool,
};

pub const CharacterSkill = struct {
    pub const table_name: []const u8 = "character_skills";
    pub const Body = BodyCharacterSkill;
    pub const Row = RowCharacterSkill;
    pub const RelationUpdate = struct {
        value: u32,
        trained: bool,
    };

    skill: Skill,
    value: u32,
    trained: bool,

    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !CharacterSkill {
        const skill = (try db.readItem(gpa, Skill, row.skill)) orelse return error.SkillNotFound;
        return fromResolvedSkill(skill, row);
    }

    fn fromResolvedSkill(skill: Skill, row: Row) CharacterSkill {
        return .{
            .skill = skill,
            .value = row.value,
            .trained = row.trained,
        };
    }

    /// Writing this collection directly is advancement, and advancement starts
    /// when creation ends. Until then the creation action owns every write, so
    /// that marking a skill trained also debits the point it costs.
    pub fn checkWritable(db: *const Database, gpa: Allocator, character_id: Character.Id) !void {
        const pools = (try db.readProjection(gpa, Character, CreationPools, character_id)) orelse
            return error.ItemNotFound;

        if (!deriveCreationComplete(pools.attribute_points, pools.trained_skill_points, pools.specialization)) {
            return error.CreationIncomplete;
        }
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

/// What a skill is worth on a finished sheet. A base chance comes from the
/// governing attribute, doubled once the skill is trained. Null means no
/// attribute decides this skill, so nothing here sets its value.
pub fn deriveStartingSkillValue(
    entry: CharacterSkill,
    attributes: []const CharacterAttribute,
    bands: []const SkillBaseChance,
) error{ CharacterAttributeNotFound, SkillBaseChanceNotFound }!?u32 {
    if (!entry.skill.kind.base_chance) return null;

    const chance = (try deriveSkillBaseChance(entry.skill, attributes, bands)) orelse return null;
    return if (entry.trained) chance * 2 else chance;
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

    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !MovementModifier {
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

/// The remaining choices a player makes after the character row has been
/// created. The URL supplies the character id, so it must not be repeated in
/// this body.
pub const BodyCharacterCreation = struct {
    specialization: ?Specialization.Id = null,
    skills: []const Skill.Id,

    pub fn validate(self: *const BodyCharacterCreation) error{DuplicateEntry}!void {
        for (self.skills, 0..) |skill, i| {
            for (self.skills[i + 1 ..]) |other| {
                if (skill == other) return error.DuplicateEntry;
            }
        }
    }
};

/// One skill row a creation save writes. The generic skills endpoint only ever
/// moves a value, so its body names one column; creation also marks the skill
/// trained, so this one names both.
const TrainedSkillWrite = struct {
    pub const key_name: []const u8 = Skill.resource_name;

    skill: Skill.Id,
    value: u32,
    trained: bool,
};

/// Everything a valid creation request changes.
pub const CreationPlan = struct {
    specialization: Specialization.Id,
    trained_skill_points: u32,
    skills: []const TrainedSkillWrite,
};

fn findSpecialization(available: []const Specialization, id: Specialization.Id) ?Specialization {
    for (available) |option| {
        if (option.id == id) return option;
    }
    return null;
}

fn findSkillEntry(entries: []const CharacterSkill, id: Skill.Id) ?CharacterSkill {
    for (entries) |entry| {
        if (entry.skill.id == id) return entry;
    }
    return null;
}

fn offersSkill(specialization: Specialization, id: Skill.Id) bool {
    for (specialization.skills) |skill| {
        if (skill.id == id) return true;
    }
    return false;
}

/// A specialization grants the skills it names that take no chance from an
/// attribute. A player learns those outright and spends no point on them.
fn isGrantedSkill(skill: Skill) bool {
    return skill.attribute != null and !skill.kind.base_chance;
}

pub const CreationError = error{
    SpecializationNotOffered,
    SpecializationLocked,
    AttributePointsRemaining,
    SkillNotTrainable,
    CreationComplete,
    NotEnoughTrainedSkillPoints,
    ProfessionSkillsReserved,
};

/// Decides a creation request against what the character has already saved,
/// and says what to write. Every rule lives here rather than among the writes,
/// which is what lets them be tested without a database.
///
/// The request is a delta. Retrying a skill that is already trained charges
/// nothing, and a completed character replaying its last request gets null
/// rather than an error. Repeated skills are the body's own rule, checked
/// before this runs.
pub fn planCreation(
    gpa: Allocator,
    character: Character,
    body: BodyCharacterCreation,
    profession_skill_minimum: u32,
) !?CreationPlan {
    const selected = body.specialization orelse return error.SpecializationNotOffered;
    const specialization = findSpecialization(character.profession.specializations, selected) orelse
        return error.SpecializationNotOffered;

    const stored = if (character.specialization) |current| current.id else null;
    const changing = stored != null and stored.? != selected;

    // A saved choice cannot be refunded, so the specialization locks as soon as
    // a point has been spent under it.
    if (changing) {
        for (character.skills) |entry| {
            if (entry.trained and entry.skill.kind.base_chance) return error.SpecializationLocked;
        }
    }

    // A specialization may be chosen while attributes are unfinished. A skill
    // may not, because its starting value comes from an attribute.
    if (body.skills.len > 0 and character.attribute_points > 0) return error.AttributePointsRemaining;

    for (body.skills) |id| {
        const entry = findSkillEntry(character.skills, id) orelse return error.SkillNotTrainable;
        if (entry.skill.attribute == null or !entry.skill.kind.base_chance) return error.SkillNotTrainable;
    }

    if (deriveCreationComplete(character.attribute_points, character.trained_skill_points, stored)) {
        if (changing) return error.CreationComplete;
        for (body.skills) |id| {
            if (!findSkillEntry(character.skills, id).?.trained) return error.CreationComplete;
        }
        return null;
    }

    var new_skills: u32 = 0;
    var new_profession_skills: u32 = 0;
    for (body.skills) |id| {
        if (findSkillEntry(character.skills, id).?.trained) continue;

        new_skills += 1;
        if (offersSkill(specialization, id)) new_profession_skills += 1;
    }

    if (new_skills > character.trained_skill_points) return error.NotEnoughTrainedSkillPoints;
    const remaining = character.trained_skill_points - new_skills;

    var saved_profession_skills: u32 = 0;
    for (character.skills) |entry| {
        if (!entry.trained or !entry.skill.kind.base_chance) continue;
        if (offersSkill(specialization, entry.skill.id)) saved_profession_skills += 1;
    }

    // Choices from outside the profession are free while enough unspent points
    // remain to still reach the minimum. Once none remain the minimum has to be
    // met already, which is the same sum with nothing left in it.
    if (saved_profession_skills + new_profession_skills + remaining < profession_skill_minimum) {
        return error.ProfessionSkillsReserved;
    }

    var writes = std.ArrayList(TrainedSkillWrite).empty;

    // A replaced specialization takes its grant with it, unless the new one
    // names the same skill.
    if (changing) {
        for (character.specialization.?.skills) |skill| {
            if (!isGrantedSkill(skill) or offersSkill(specialization, skill.id)) continue;
            try writes.append(gpa, .{ .skill = skill.id, .value = 0, .trained = false });
        }
    }

    for (specialization.skills) |skill| {
        if (!isGrantedSkill(skill)) continue;
        try writes.append(gpa, .{ .skill = skill.id, .value = 1, .trained = true });
    }

    // A trained skill is worth twice its starting chance, which is the value
    // the sheet already holds once every attribute point is spent.
    for (body.skills) |id| {
        const entry = findSkillEntry(character.skills, id).?;
        if (entry.trained) continue;

        try writes.append(gpa, .{ .skill = id, .value = entry.value * 2, .trained = true });
    }

    return .{
        .specialization = selected,
        .trained_skill_points = remaining,
        .skills = try writes.toOwnedSlice(gpa),
    };
}

/// One attribute row an age change writes. Only the rules' column moves; what
/// the player spent is theirs and never changes here.
const AgeModifierWrite = struct {
    pub const key_name: []const u8 = Attribute.resource_name;

    attribute: Attribute.Id,
    modifier: i32,
};

/// The stored state an age or profession change invalidates.
const StoredCreation = struct {
    profession: Profession.Id,
    age: Age.Id,
    specialization: ?Specialization.Id,
    attribute_points: u32,
};

/// What a new age does to a sheet's attributes. An age adjusts a few and says
/// nothing about the rest, and silence means zero rather than no change.
pub fn planAgeModifiers(
    gpa: Allocator,
    attributes: []const CharacterAttribute,
    age_modifiers: []const AgeAttribute,
) ![]const AgeModifierWrite {
    var writes = std.ArrayList(AgeModifierWrite).empty;
    errdefer writes.deinit(gpa);

    for (attributes) |entry| {
        var modifier: i32 = 0;
        for (age_modifiers) |adjustment| {
            if (adjustment.attribute == entry.attribute.id) modifier = adjustment.modifier;
        }
        if (modifier == entry.modifier) continue;

        try writes.append(gpa, .{ .attribute = entry.attribute.id, .modifier = modifier });
    }

    return writes.toOwnedSlice(gpa);
}

/// What an age or profession change does to a sheet's skills. Every choice made
/// under the old one goes: training is cleared, and each skill falls back to
/// what its attribute alone gives, or to zero while the attributes are still
/// unfinished. A specialization the character keeps grants its skill again.
pub fn planCreationReset(
    gpa: Allocator,
    entries: []const CharacterSkill,
    attributes: []const CharacterAttribute,
    bands: []const SkillBaseChance,
    specialization: ?Specialization,
    attributes_finished: bool,
) ![]const TrainedSkillWrite {
    var writes = std.ArrayList(TrainedSkillWrite).empty;
    errdefer writes.deinit(gpa);

    for (entries) |entry| {
        var cleared = entry;
        cleared.trained = false;

        const value = if (attributes_finished)
            (try deriveStartingSkillValue(cleared, attributes, bands)) orelse 0
        else
            0;

        if (!entry.trained and entry.value == value) continue;

        try writes.append(gpa, .{ .skill = entry.skill.id, .value = value, .trained = false });
    }

    if (specialization) |kept| {
        for (kept.skills) |skill| {
            if (!isGrantedSkill(skill)) continue;

            try writes.append(gpa, .{ .skill = skill.id, .value = 1, .trained = true });
        }
    }

    return writes.toOwnedSlice(gpa);
}

/// The non-row operation exposed at /characters/:id/creation. The rules live in
/// planCreation; this reads what they need and writes what they decide.
pub const CharacterCreation = struct {
    pub const Body = BodyCharacterCreation;

    pub fn apply(db: *const Database, gpa: Allocator, character_id: Character.Id, body: Body) !void {
        const character = (try db.readItem(gpa, Character, character_id)) orelse return error.ItemNotFound;
        const minimum = try Config.readCount(db, gpa, Config.profession_skill_minimum);

        const plan = (try planCreation(gpa, character, body, minimum)) orelse return;

        try db.updateColumns(gpa, Character, character_id, .{
            .specialization = plan.specialization,
            .trained_skill_points = plan.trained_skill_points,
        });
        try db.updateSubRows(gpa, Character, CharacterSkill, TrainedSkillWrite, character_id, plan.skills);
    }
};

pub const RowCharacter = struct {
    id: Character.Id,
    name: []const u8,
    level: u32,
    kin: Kin.Id,
    profession: Profession.Id,
    specialization: ?Specialization.Id,
    age: Age.Id,
    attribute_points: u32,
    trained_skill_points: u32,
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

    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !CharacterSummary {
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

/// The one column a new character needs from its age.
const AgeTrainedSkillCount = struct {
    trained_skill_count: u32,
};

/// A character's specialization is one its profession offers. A profession
/// that does not offer the stored choice replaces it, with its sole
/// specialization when it has exactly one and with nothing when the player
/// still has a choice to make.
pub fn deriveSpecialization(available: []const Specialization, current: ?Specialization.Id) ?Specialization.Id {
    if (current) |chosen| {
        for (available) |option| {
            if (option.id == chosen) return chosen;
        }
    }
    return if (available.len == 1) available[0].id else null;
}

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
    specialization: ?Specialization,
    age: Age,
    attribute_points: u32,
    trained_skill_points: u32,
    creation_complete: bool,
    /// Derived from the kin and the sheet on every read: see deriveMovement.
    movement: i32,
    damage_bonuses: []const CharacterDamageBonus,
    attributes: []const CharacterAttribute,
    skills: []const CharacterSkill,

    /// Unlike the other models, a character is not one row: its attribute and
    /// skill values live in their own tables and are fetched here, keyed by
    /// this character's id.
    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !Character {
        const summary = try CharacterSummary.fromRow(db, gpa, row);
        const attributes = try db.readSubResource(gpa, Character, CharacterAttribute, row.id);
        const bands = try db.readAllAlloc(gpa, MovementModifier);
        const rules = try db.readAllAlloc(gpa, DamageBonus);
        const specialization = if (row.specialization) |id|
            (try db.readItem(gpa, Specialization, id)) orelse return error.SpecializationNotFound
        else
            null;
        const skills = try db.readSubResource(gpa, Character, CharacterSkill, row.id);

        return .{
            .id = summary.id,
            .name = summary.name,
            .level = summary.level,
            .kin = summary.kin,
            .profession = summary.profession,
            .specialization = specialization,
            .age = summary.age,
            .attribute_points = row.attribute_points,
            .trained_skill_points = row.trained_skill_points,
            .creation_complete = deriveCreationComplete(row.attribute_points, row.trained_skill_points, row.specialization),
            .movement = deriveMovement(summary.kin.movement, attributes, bands),
            .damage_bonuses = try deriveDamageBonuses(gpa, attributes, rules),
            .attributes = attributes,
            .skills = skills,
        };
    }

    /// A kin supplies abilities that a new character knows from the start.
    /// Every character already has the row from the database seed trigger; this
    /// only marks that one row learned and does not spend a training point.
    fn learnInnateSkill(db: *const Database, gpa: Allocator, character_id: Character.Id, skill: Skill) !void {
        if (!std.mem.eql(u8, skill.kind.name, "Innate")) return error.SkillNotInnate;

        try db.updateRelation(gpa, Character, Skill, CharacterSkill, character_id, skill.id, .{
            .value = 1,
            .trained = true,
        });
    }

    /// The pool a character trains skills from is the one its age allows. The
    /// player never sends it, so it is written here, in the transaction that
    /// inserts the row.
    pub fn afterInsert(db: *const Database, gpa: Allocator, id: Id, create: Create) !void {
        const age = (try db.readProjection(gpa, Age, AgeTrainedSkillCount, create.age)) orelse
            return error.AgeNotFound;
        const profession = (try db.readItem(gpa, Profession, create.profession)) orelse
            return error.ProfessionNotFound;
        const kin = (try db.readItem(gpa, Kin, create.kin)) orelse
            return error.KinNotFound;

        try db.updateColumns(gpa, Character, id, .{
            .trained_skill_points = age.trained_skill_count,
            .specialization = deriveSpecialization(profession.specializations, null),
        });
        for (kin.skills) |skill| {
            try learnInnateSkill(db, gpa, id, skill);
        }
    }

    /// A new age or profession invalidates every choice made under the old one.
    /// The whole reset happens before the row changes, so it and the update
    /// commit together and no half-reset sheet is ever readable.
    pub fn beforeUpdate(db: *const Database, gpa: Allocator, id: Id, update: Update) !void {
        const stored = (try db.readProjection(gpa, Character, StoredCreation, id)) orelse
            return error.ItemNotFound;
        const profession = (try db.readItem(gpa, Profession, update.profession)) orelse
            return error.ProfessionNotFound;

        const specialization = deriveSpecialization(profession.specializations, stored.specialization);

        // An unchanged age and profession leave every earlier choice standing,
        // along with the points already spent on them.
        if (update.age == stored.age and update.profession == stored.profession) {
            if (specialization != stored.specialization) {
                try db.updateColumns(gpa, Character, id, .{ .specialization = specialization });
            }
            return;
        }

        const age = (try db.readItem(gpa, Age, update.age)) orelse return error.AgeNotFound;

        try db.updateColumns(gpa, Character, id, .{
            .specialization = specialization,
            .trained_skill_points = age.trained_skill_count,
        });

        if (update.age != stored.age) {
            const current = try db.readSubResource(gpa, Character, CharacterAttribute, id);
            const age_modifiers = try db.readSubResource(gpa, Age, AgeAttribute, update.age);
            const modifiers = try planAgeModifiers(gpa, current, age_modifiers);

            try db.updateSubRows(gpa, Character, CharacterAttribute, AgeModifierWrite, id, modifiers);
        }

        // Read the sheet after the modifiers land: a skill's chance follows the
        // attribute the new age has just adjusted.
        const attributes = try db.readSubResource(gpa, Character, CharacterAttribute, id);
        const bands = try db.readAllAlloc(gpa, SkillBaseChance);
        const entries = try db.readSubResource(gpa, Character, CharacterSkill, id);
        const kept = if (specialization) |chosen|
            findSpecialization(profession.specializations, chosen)
        else
            null;

        const writes = try planCreationReset(gpa, entries, attributes, bands, kept, stored.attribute_points == 0);
        try db.updateSubRows(gpa, Character, CharacterSkill, TrainedSkillWrite, id, writes);
    }
};

/// The columns creation status is read from, for a caller that wants the
/// status alone. Reading the whole character costs a query per nested record.
const CreationPools = struct {
    attribute_points: u32,
    trained_skill_points: u32,
    specialization: ?Specialization.Id,
};

/// Creation status is a view of persisted choices. The served JSON and the
/// guard on direct skill writes both read it here, so the two cannot disagree
/// after a profession, age, or attribute-point update. Whether a
/// specialization was chosen is what counts, not which one.
pub fn deriveCreationComplete(
    attribute_points: u32,
    trained_skill_points: u32,
    specialization: ?Specialization.Id,
) bool {
    return attribute_points == 0 and trained_skill_points == 0 and specialization != null;
}

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
    const kin = Kin{ .id = 1, .name = "Elf", .icon = icon, .movement = 10, .skills = &.{} };
    const profession = Profession{ .id = 1, .name = "Warrior", .icon = icon, .description = "A strong melee fighter", .specializations = &.{} };
    const age = Age{ .id = 1, .name = "Old", .icon = icon, .trained_skill_count = 8 };
    const character = Character{
        .id = 1,
        .name = "Alice",
        .level = 2,
        .kin = kin,
        .profession = profession,
        .specialization = null,
        .age = age,
        .attribute_points = 54,
        .trained_skill_points = 8,
        .creation_complete = false,
        .movement = 10,
        .damage_bonuses = &.{},
        .attributes = &.{},
        .skills = &.{},
    };
    try std.json.Stringify.value(character, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"},"movement":10,"skills":[]},"profession":{"id":1,"name":"Warrior","icon":{"id":1,"name":"abacus"},"description":"A strong melee fighter","specializations":[]},"specialization":null,"age":{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"},"trained_skill_count":8},"attribute_points":54,"trained_skill_points":8,"creation_complete":false,"movement":10,"damage_bonuses":[],"attributes":[],"skills":[]}
    , out.written());
}

test "a summary is a character without its sheet" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const icon = Icon{ .id = 1, .name = "abacus" };
    const kin = Kin{ .id = 1, .name = "Elf", .icon = icon, .movement = 10, .skills = &.{} };
    const profession = Profession{ .id = 1, .name = "Warrior", .icon = icon, .description = "A strong melee fighter", .specializations = &.{} };
    const age = Age{ .id = 1, .name = "Old", .icon = icon, .trained_skill_count = 8 };
    const summary = CharacterSummary{ .id = 1, .name = "Alice", .level = 2, .kin = kin, .profession = profession, .age = age };
    try std.json.Stringify.value(summary, .{}, &out.writer);

    // The roster renders these four fields, so this is all a list has to carry.
    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"},"movement":10,"skills":[]},"profession":{"id":1,"name":"Warrior","icon":{"id":1,"name":"abacus"},"description":"A strong melee fighter","specializations":[]},"age":{"id":1,"name":"Old","icon":{"id":1,"name":"abacus"},"trained_skill_count":8}}
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

test "CharacterCreation parses the persisted choice body and rejects repeated skills" {
    const parsed = try std.json.parseFromSlice(
        BodyCharacterCreation,
        std.testing.allocator,
        \\{"specialization":4,"skills":[3,7,9]}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(?Specialization.Id, 4), parsed.value.specialization);
    try std.testing.expectEqualSlices(Skill.Id, &.{ 3, 7, 9 }, parsed.value.skills);
    try parsed.value.validate();

    const repeated = BodyCharacterCreation{ .specialization = 4, .skills = &.{ 3, 7, 3 } };
    try std.testing.expectError(error.DuplicateEntry, repeated.validate());
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
    try std.testing.expect(!@hasField(BodyCharacterCreation, "character"));
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
    .kind = .{ .id = 1, .name = "Core", .base_chance = true },
    .attribute = test_agility,
    .description = "Body control.",
};

fn testSpecialization(id: Specialization.Id) Specialization {
    return .{
        .id = id,
        .name = "Test",
        .description = "Test specialization.",
        .skills = &.{},
        .heroic_skill = null,
        .items = &.{},
    };
}

test "a specialization lasts only as long as its profession offers it" {
    const several = [_]Specialization{ testSpecialization(1), testSpecialization(2) };
    const sole = [_]Specialization{testSpecialization(1)};

    // One specialization leaves the player nothing to decide, so it is chosen
    // even over a stored choice that belonged to another profession.
    try std.testing.expectEqual(@as(?Specialization.Id, 1), deriveSpecialization(&sole, null));
    try std.testing.expectEqual(@as(?Specialization.Id, 1), deriveSpecialization(&sole, 2));

    // Several keep a valid choice and drop one the profession does not offer.
    try std.testing.expectEqual(@as(?Specialization.Id, 2), deriveSpecialization(&several, 2));
    try std.testing.expectEqual(@as(?Specialization.Id, null), deriveSpecialization(&several, null));
    try std.testing.expectEqual(@as(?Specialization.Id, null), deriveSpecialization(&several, 7));
}

test "creation completion is derived from the two exhausted point pools" {
    const specialization: Specialization.Id = 1;

    try std.testing.expect(deriveCreationComplete(0, 0, specialization));
    try std.testing.expect(!deriveCreationComplete(1, 0, specialization));
    try std.testing.expect(!deriveCreationComplete(0, 1, specialization));
    try std.testing.expect(!deriveCreationComplete(0, 0, null));
}

test "CharacterSkill reads its saved value and explicit training state" {
    const row = RowCharacterSkill{ .character = 47, .skill = test_acrobatics.id, .value = 12, .trained = true };
    const entry = CharacterSkill.fromResolvedSkill(test_acrobatics, row);
    try std.testing.expectEqual(@as(u32, 12), entry.value);
    try std.testing.expect(entry.trained);
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

test "training doubles a starting value, and only a base-chance skill has one" {
    const sheet = [_]CharacterAttribute{
        .{ .attribute = test_agility, .base = 3, .spent = 10, .modifier = 0, .value = 13 },
    };
    const bands = [_]SkillBaseChance{.{ .min_value = 13, .max_value = 15, .base_chance = 6 }};

    const untrained = CharacterSkill{ .skill = test_acrobatics, .value = 0, .trained = false };
    var trained = untrained;
    trained.trained = true;

    try std.testing.expectEqual(@as(?u32, 6), try deriveStartingSkillValue(untrained, &sheet, &bands));
    try std.testing.expectEqual(@as(?u32, 12), try deriveStartingSkillValue(trained, &sheet, &bands));

    // A kind without a base chance takes no value from an attribute, trained
    // or not, so the refresh leaves whatever the rules put there.
    var secondary = trained;
    secondary.skill.kind = .{ .id = 2, .name = "Secondary", .base_chance = false };
    try std.testing.expectEqual(@as(?u32, null), try deriveStartingSkillValue(secondary, &sheet, &bands));
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

const test_icon = Icon{ .id = 1, .name = "abacus" };

fn testCoreSkill(id: Skill.Id) Skill {
    var skill = test_acrobatics;
    skill.id = id;
    return skill;
}

/// A skill a specialization hands out: governed by an attribute, but with no
/// base chance, so it is learned rather than rolled for.
fn testGrantedSkill(id: Skill.Id) Skill {
    var skill = testCoreSkill(id);
    skill.kind = .{ .id = 2, .name = "Secondary", .base_chance = false };
    return skill;
}

// One profession offering two specializations. Skills 1 and 2 are on both, 3
// and 4 only on the first, and each specialization grants one skill of its own.
var test_first_skills = [_]Skill{ testCoreSkill(1), testCoreSkill(2), testCoreSkill(3), testCoreSkill(4), testGrantedSkill(9) };
var test_second_skills = [_]Skill{ testCoreSkill(1), testCoreSkill(2), testGrantedSkill(10) };
var test_professsion_specializations = [_]Specialization{
    .{ .id = 1, .name = "First", .description = "d", .skills = &test_first_skills, .heroic_skill = null, .items = &.{} },
    .{ .id = 2, .name = "Second", .description = "d", .skills = &test_second_skills, .heroic_skill = null, .items = &.{} },
};

fn testCharacter(specialization: ?Specialization, attribute_points: u32, pool: u32, skills: []const CharacterSkill) Character {
    return .{
        .id = 1,
        .name = "Test",
        .level = 1,
        .kin = .{ .id = 1, .name = "Elf", .icon = test_icon, .movement = 10, .skills = &.{} },
        .profession = .{ .id = 1, .name = "Artisan", .icon = test_icon, .description = "d", .specializations = &test_professsion_specializations },
        .specialization = specialization,
        .age = .{ .id = 1, .name = "Young", .icon = test_icon, .trained_skill_count = 8 },
        .attribute_points = attribute_points,
        .trained_skill_points = pool,
        .creation_complete = deriveCreationComplete(attribute_points, pool, if (specialization) |chosen| chosen.id else null),
        .movement = 10,
        .damage_bonuses = &.{},
        .attributes = &.{},
        .skills = skills,
    };
}

/// A finished sheet: every core skill at its starting chance, nothing trained,
/// and both grants unlearned.
fn testSheet() [7]CharacterSkill {
    return .{
        .{ .skill = testCoreSkill(1), .value = 5, .trained = false },
        .{ .skill = testCoreSkill(2), .value = 5, .trained = false },
        .{ .skill = testCoreSkill(3), .value = 5, .trained = false },
        .{ .skill = testCoreSkill(4), .value = 5, .trained = false },
        .{ .skill = testCoreSkill(5), .value = 5, .trained = false },
        .{ .skill = testGrantedSkill(9), .value = 0, .trained = false },
        .{ .skill = testGrantedSkill(10), .value = 0, .trained = false },
    };
}

fn expectWrite(plan: CreationPlan, skill: Skill.Id, value: u32, trained: bool) !void {
    for (plan.skills) |write| {
        if (write.skill != skill) continue;

        try std.testing.expectEqual(value, write.value);
        try std.testing.expectEqual(trained, write.trained);
        return;
    }
    std.debug.print("no write for skill {d}\n", .{skill});
    return error.TestExpectedWrite;
}

test "a creation save trains the chosen skills and grants the specialization's own" {
    const sheet = testSheet();
    const character = testCharacter(null, 0, 8, &sheet);
    const body = BodyCharacterCreation{ .specialization = 1, .skills = &.{ 1, 2 } };

    const plan = (try planCreation(std.testing.allocator, character, body, 2)).?;
    defer std.testing.allocator.free(plan.skills);

    try std.testing.expectEqual(@as(Specialization.Id, 1), plan.specialization);
    try std.testing.expectEqual(@as(u32, 6), plan.trained_skill_points);

    // A trained skill doubles what the sheet already holds; a granted one is
    // learned outright at one and costs no point.
    try expectWrite(plan, 1, 10, true);
    try expectWrite(plan, 2, 10, true);
    try expectWrite(plan, 9, 1, true);
    try std.testing.expectEqual(@as(usize, 3), plan.skills.len);
}

test "retrying a trained skill charges nothing" {
    var sheet = testSheet();
    sheet[0] = .{ .skill = testCoreSkill(1), .value = 10, .trained = true };
    const character = testCharacter(test_professsion_specializations[0], 0, 7, &sheet);
    const body = BodyCharacterCreation{ .specialization = 1, .skills = &.{ 1, 2 } };

    const plan = (try planCreation(std.testing.allocator, character, body, 2)).?;
    defer std.testing.allocator.free(plan.skills);

    // Only skill 2 is new, so only one point leaves the pool and skill 1 keeps
    // the value it was already given.
    try std.testing.expectEqual(@as(u32, 6), plan.trained_skill_points);
    try expectWrite(plan, 2, 10, true);
    for (plan.skills) |write| try std.testing.expect(write.skill != 1);
}

test "replacing a specialization takes back the skill it granted" {
    var sheet = testSheet();
    sheet[5] = .{ .skill = testGrantedSkill(9), .value = 1, .trained = true };
    const character = testCharacter(test_professsion_specializations[0], 0, 8, &sheet);
    const body = BodyCharacterCreation{ .specialization = 2, .skills = &.{} };

    const plan = (try planCreation(std.testing.allocator, character, body, 2)).?;
    defer std.testing.allocator.free(plan.skills);

    try expectWrite(plan, 9, 0, false);
    try expectWrite(plan, 10, 1, true);
    try std.testing.expectEqual(@as(u32, 8), plan.trained_skill_points);
}

test "a completed character may replay its last request but not extend it" {
    var sheet = testSheet();
    sheet[0] = .{ .skill = testCoreSkill(1), .value = 10, .trained = true };
    const character = testCharacter(test_professsion_specializations[0], 0, 0, &sheet);

    const replay = BodyCharacterCreation{ .specialization = 1, .skills = &.{1} };
    try std.testing.expectEqual(@as(?CreationPlan, null), try planCreation(std.testing.allocator, character, replay, 2));

    const extend = BodyCharacterCreation{ .specialization = 1, .skills = &.{2} };
    try std.testing.expectError(error.CreationComplete, planCreation(std.testing.allocator, character, extend, 2));

    // Moving specialization is refused by the lock rather than by completion:
    // a finished character has spent points, and the lock is checked first.
    const move = BodyCharacterCreation{ .specialization = 2, .skills = &.{} };
    try std.testing.expectError(error.SpecializationLocked, planCreation(std.testing.allocator, character, move, 2));
}

test "each creation rule refuses its own request" {
    const gpa = std.testing.allocator;
    const sheet = testSheet();
    const fresh = testCharacter(null, 0, 8, &sheet);

    // A specialization the profession does not offer, or none at all.
    try std.testing.expectError(error.SpecializationNotOffered, planCreation(gpa, fresh, .{ .specialization = null, .skills = &.{} }, 2));
    try std.testing.expectError(error.SpecializationNotOffered, planCreation(gpa, fresh, .{ .specialization = 99, .skills = &.{} }, 2));

    // A point already spent under the stored specialization locks it.
    var spent = testSheet();
    spent[0] = .{ .skill = testCoreSkill(1), .value = 10, .trained = true };
    const started = testCharacter(test_professsion_specializations[0], 0, 7, &spent);
    try std.testing.expectError(error.SpecializationLocked, planCreation(gpa, started, .{ .specialization = 2, .skills = &.{} }, 2));

    // Skills wait for the attribute pool, but a specialization does not.
    const drafting = testCharacter(null, 4, 8, &sheet);
    try std.testing.expectError(error.AttributePointsRemaining, planCreation(gpa, drafting, .{ .specialization = 1, .skills = &.{1} }, 2));
    const draft = (try planCreation(gpa, drafting, .{ .specialization = 1, .skills = &.{} }, 2)).?;
    gpa.free(draft.skills);

    // A granted skill is not a choice, and neither is a skill nobody has.
    try std.testing.expectError(error.SkillNotTrainable, planCreation(gpa, fresh, .{ .specialization = 1, .skills = &.{9} }, 2));
    try std.testing.expectError(error.SkillNotTrainable, planCreation(gpa, fresh, .{ .specialization = 1, .skills = &.{77} }, 2));

    // More choices than the pool can pay for.
    const nearly_done = testCharacter(null, 0, 1, &sheet);
    try std.testing.expectError(error.NotEnoughTrainedSkillPoints, planCreation(gpa, nearly_done, .{ .specialization = 1, .skills = &.{ 1, 2 } }, 2));

    // Skill 5 is outside the profession, and spending the last two points on it
    // leaves no way to reach a minimum of two.
    const two_left = testCharacter(null, 0, 2, &sheet);
    try std.testing.expectError(error.ProfessionSkillsReserved, planCreation(gpa, two_left, .{ .specialization = 1, .skills = &.{5} }, 2));
}

test "a new age sets every modifier it names and clears the ones it does not" {
    const sheet = [_]CharacterAttribute{
        .{ .attribute = test_agility, .base = 3, .spent = 0, .modifier = 2, .value = 5 },
        .{ .attribute = test_strength, .base = 3, .spent = 0, .modifier = 0, .value = 3 },
    };
    // The new age says nothing about agility and adds one to strength.
    const age_modifiers = [_]AgeAttribute{.{ .age = 2, .attribute = test_strength.id, .modifier = 1 }};

    const writes = try planAgeModifiers(std.testing.allocator, &sheet, &age_modifiers);
    defer std.testing.allocator.free(writes);

    try std.testing.expectEqual(@as(usize, 2), writes.len);
    try std.testing.expectEqual(AgeModifierWrite{ .attribute = test_agility.id, .modifier = 0 }, writes[0]);
    try std.testing.expectEqual(AgeModifierWrite{ .attribute = test_strength.id, .modifier = 1 }, writes[1]);

    // An age that changes nothing writes nothing.
    const settled = [_]CharacterAttribute{
        .{ .attribute = test_strength, .base = 3, .spent = 0, .modifier = 1, .value = 4 },
    };
    const none = try planAgeModifiers(std.testing.allocator, &settled, &age_modifiers);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "an age or profession change clears training and keeps the grant" {
    const gpa = std.testing.allocator;
    const attributes = sheetWithAgility(13);
    const bands = [_]SkillBaseChance{.{ .min_value = 13, .max_value = 15, .base_chance = 6 }};

    var sheet = testSheet();
    sheet[0] = .{ .skill = testCoreSkill(1), .value = 12, .trained = true };
    sheet[5] = .{ .skill = testGrantedSkill(9), .value = 1, .trained = true };

    const writes = try planCreationReset(gpa, &sheet, &attributes, &bands, test_professsion_specializations[0], true);
    defer gpa.free(writes);

    // A trained core skill falls back to the single chance, and the grant is
    // cleared before the specialization hands it out again.
    const plan = CreationPlan{ .specialization = 1, .trained_skill_points = 0, .skills = writes };
    try expectWrite(plan, 1, 6, false);
    try expectWrite(plan, 5, 6, false);
    try std.testing.expectEqual(TrainedSkillWrite{ .skill = 9, .value = 1, .trained = true }, writes[writes.len - 1]);

    // Skill 10 is another specialization's grant, already at zero, so nothing
    // about it changes.
    for (writes) |write| try std.testing.expect(write.skill != 10);
}

test "an unfinished sheet resets to zero rather than to a chance" {
    const gpa = std.testing.allocator;
    const attributes = sheetWithAgility(13);
    const bands = [_]SkillBaseChance{.{ .min_value = 13, .max_value = 15, .base_chance = 6 }};

    const sheet = testSheet();
    const writes = try planCreationReset(gpa, &sheet, &attributes, &bands, null, false);
    defer gpa.free(writes);

    // Every core skill in the fixture holds 5, and none of them keeps it.
    for (writes) |write| {
        try std.testing.expectEqual(@as(u32, 0), write.value);
        try std.testing.expect(!write.trained);
    }
    try std.testing.expectEqual(@as(usize, 5), writes.len);
}
