// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

/// An inclusive attribute band and the free skill level it grants.
pub const SkillBaseChance = struct {
    pub const table_name = "skill_base_chances";
    pub const order_by = "min_value";

    min_value: u32,
    max_value: u32,
    base_chance: u32,
};
