// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const character = @import("character.zig");
pub const Character = character.Character;
pub const CharacterAttribute = character.CharacterAttribute;
pub const CharacterSkill = character.CharacterSkill;

const icon = @import("icon.zig");
pub const Icon = icon.Icon;

const attribute = @import("attribute.zig");
pub const Attribute = attribute.Attribute;

const kin = @import("kin.zig");
pub const Kin = kin.Kin;

const skill = @import("skill.zig");
pub const Skill = skill.Skill;
pub const SkillKind = skill.SkillKind;

test {
    // Test discovery is lazy: a file's tests are only collected when the file
    // is referenced from a test context, so name each model file here.
    _ = character;
    _ = kin;
    _ = skill;
    _ = icon;
    _ = attribute;
}

/// Every model a query can return, including the two join-table rows.
const all_models = .{ Character, CharacterAttribute, CharacterSkill, Icon, Attribute, Kin, Skill, SkillKind };

test "models are plain data" {
    // A query result lives in the request's arena and is released with it, so
    // a model owns nothing. An `init` here would copy strings that rowToT has
    // already copied, and a `deinit` would free memory the arena frees anyway
    // -- and would be wrong to call, since models share their nested records.
    // Reintroducing either means reintroducing ownership: decide that on
    // purpose rather than by adding a constructor out of habit.
    inline for (all_models) |Model| {
        try std.testing.expect(!@hasDecl(Model, "init"));
        try std.testing.expect(!@hasDecl(Model, "deinit"));
    }
}
