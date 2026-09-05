// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! The `zttrpg` module: the domain models and the queries that read and write
//! them. This file only re-exports; each name below is defined in its own file.

const model = @import("model/model.zig");

pub const Age = model.Age;
pub const Attribute = model.Attribute;
pub const Character = model.Character;
pub const CharacterAttribute = model.CharacterAttribute;
pub const CharacterSkill = model.CharacterSkill;
pub const CharacterSummary = model.CharacterSummary;
pub const Config = model.Config;
pub const Icon = model.Icon;
pub const Kin = model.Kin;
pub const Skill = model.Skill;
pub const SkillKind = model.SkillKind;

const database = @import("database.zig");

pub const Database = database.Database;

test {
    // Test discovery is lazy: a file's tests are collected only when the file
    // is referenced from a test context, so name every file this module owns.
    _ = model;
    _ = database;
}
