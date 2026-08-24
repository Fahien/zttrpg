// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

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
