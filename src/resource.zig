// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! Resource registration connects URL names to models and HTTP capabilities.
//! The route parser and handlers use this table for every resource.

const zttrpg = @import("zttrpg");

/// The model type and HTTP capabilities for one registered resource.
///
/// The handler reads collections as `Model.Summary` when that declaration
/// exists. It reads items as `Model`. A `Model.Row` and `fromRow` declaration
/// can convert stored columns into a nested served model.
pub const Definition = struct {
    /// The model used for collection reads and item operations.
    Model: type,

    /// Whether `/{resource}/{id}` identifies an individual record.
    /// All item reads and writes require this capability.
    item: bool = true,

    /// Whether POST creates a record in the collection.
    /// The body type is `Model.Create`, which must provide `validate`.
    /// This also requires `item` because the response reads the created item.
    create: bool = true,

    /// Whether PUT replaces a record at `/{resource}/{id}`.
    /// The body type is `Model.Update`, which must provide `validate`.
    update: bool = true,

    /// Whether DELETE removes a record at `/{resource}/{id}`.
    delete: bool = true,

    /// Whether browser GET requests can serve the HTML pages for this resource.
    /// The handler serves JSON when this is false or Accept is exactly JSON.
    html: bool = true,
};

/// A URL resource and its model registration.
///
/// Each tag becomes a top-level URL segment and an HTML directory name.
/// Adding a tag and a `definition` arm is enough to connect a model to the
/// generic route and handler code.
pub const Resource = enum {
    item_kinds,
    item_supplies,
    items,
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

    /// Return the model and HTTP capabilities for this resource.
    ///
    /// The default capabilities enable collection GET and POST, item GET,
    /// PUT, and DELETE, and HTML pages. Set a capability to false when the
    /// resource does not support that operation.
    pub fn definition(comptime resource: Resource) Definition {
        return switch (resource) {
            .item_kinds => .{ .Model = zttrpg.ItemKind },
            .item_supplies => .{ .Model = zttrpg.ItemSupply },
            .items => .{ .Model = zttrpg.Item },
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
