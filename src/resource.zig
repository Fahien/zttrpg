// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const zttrpg = @import("zttrpg");

/// HTTP capabilities belong to the resource registration. Models describe
/// game data; routing and handlers consume this metadata generically.
pub const Definition = struct {
    Model: type,
    item: bool = true,
    create: bool = true,
    update: bool = true,
    delete: bool = true,
    html: bool = true,
};

pub const Resource = enum {
    ages,
    configs,
    movement_modifiers,
    damage_bonuses,
    characters,
    kins,
    skill_kinds,
    skills,
    icons,
    attributes,

    /// One registration ties a URL name to its model and supported operations.
    pub fn definition(comptime resource: Resource) Definition {
        return switch (resource) {
            .ages => .{ .Model = zttrpg.Age },
            .configs => .{ .Model = zttrpg.Config },
            .movement_modifiers => .{ .Model = zttrpg.MovementModifier },
            .damage_bonuses => .{
                .Model = zttrpg.DamageBonus,
                .item = false,
                .create = false,
                .update = false,
                .delete = false,
                .html = false,
            },
            .characters => .{ .Model = zttrpg.Character },
            .kins => .{ .Model = zttrpg.Kin },
            .skill_kinds => .{ .Model = zttrpg.SkillKind },
            .skills => .{ .Model = zttrpg.Skill },
            .icons => .{ .Model = zttrpg.Icon },
            .attributes => .{ .Model = zttrpg.Attribute },
        };
    }
};
