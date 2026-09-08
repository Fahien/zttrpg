// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const config = @import("config.zig");
pub const Config = config.Config;

const item_supply = @import("item_supply.zig");
pub const ItemSupply = item_supply.ItemSupply;
const item_kind = @import("item_kind.zig");
pub const ItemKind = item_kind.ItemKind;
const item = @import("item.zig");
pub const Item = item.Item;

const age = @import("age.zig");
pub const Age = age.Age;

const character = @import("character.zig");
pub const Character = character.Character;
pub const CharacterAttribute = character.CharacterAttribute;
pub const CharacterSkill = character.CharacterSkill;
pub const CharacterSummary = character.CharacterSummary;
pub const MovementModifier = character.MovementModifier;

const damage_bonus = @import("damage_bonus.zig");
pub const DamageBonus = damage_bonus.DamageBonus;

const icon = @import("icon.zig");
pub const Icon = icon.Icon;

const attribute = @import("attribute.zig");
pub const Attribute = attribute.Attribute;

const kin = @import("kin.zig");
pub const Kin = kin.Kin;

const skill = @import("skill.zig");
pub const Skill = skill.Skill;
pub const SkillKind = skill.SkillKind;

const skill_base_chance = @import("skill_base_chance.zig");
pub const SkillBaseChance = skill_base_chance.SkillBaseChance;

test {
    // Test discovery is lazy: a file's tests are only collected when the file
    // is referenced from a test context, so name each model file here.
    std.testing.refAllDecls(@This());
}

test "a model that splits its stored shape says how to rebuild itself" {
    // Database.hydrate is generic: for any model whose Row differs from the
    // model itself, it calls fromRow and knows nothing else about it. Declaring
    // one without the other is the mistake this catches -- and it catches it
    // for every model, not just the ones some query happens to instantiate.
    const all_decls = comptime std.meta.declarations(@This());
    inline for (all_decls) |decl| {
        const Model = @field(@This(), decl.name);
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
    const all_decls = comptime std.meta.declarations(@This());
    inline for (all_decls) |decl| {
        const Model = @field(@This(), decl.name);
        try std.testing.expect(!@hasDecl(Model, "init"));
        try std.testing.expect(!@hasDecl(Model, "deinit"));
    }
}
