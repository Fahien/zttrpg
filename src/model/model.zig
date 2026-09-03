// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const age = @import("age.zig");
pub const Age = age.Age;

const character = @import("character.zig");
pub const Character = character.Character;
pub const CharacterAttribute = character.CharacterAttribute;
pub const CharacterSkill = character.CharacterSkill;
pub const CharacterSummary = character.CharacterSummary;

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
    _ = age;
    _ = character;
    _ = kin;
    _ = skill;
    _ = icon;
    _ = attribute;
}

/// Every model a query can return, including the two join-table rows.
const all_models = .{ Age, Character, CharacterSummary, CharacterAttribute, CharacterSkill, Icon, Attribute, Kin, Skill, SkillKind };

test "a model that splits its stored shape says how to rebuild itself" {
    // Database.hydrate is generic: for any model whose Row differs from the
    // model itself, it calls fromRow and knows nothing else about it. Declaring
    // one without the other is the mistake this catches -- and it catches it
    // for every model, not just the ones some query happens to instantiate.
    inline for (all_models) |Model| {
        if (@hasDecl(Model, "Row")) {
            try std.testing.expect(@hasDecl(Model, "fromRow"));
        }
    }
}

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
