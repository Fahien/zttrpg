// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const Attribute = @import("attribute.zig").Attribute;

/// A threshold from the damage_bonuses table. The attribute stays an id so
/// reading the rules needs no additional queries for attribute records.
pub const DamageBonus = struct {
    pub const table_name = "damage_bonuses";
    pub const order_by = "attribute, min_value";

    attribute: Attribute.Id,
    min_value: u32,
    die_sides: u32,
};
