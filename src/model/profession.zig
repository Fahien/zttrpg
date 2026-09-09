// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! A profession supplies shared presentation data and one or more complete
//! specializations. Mechanics belong to the specialization: it owns its
//! starting skills, nullable heroic skill, and selectable gear packages.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;
const Item = @import("item.zig").Item;
const Skill = @import("skill.zig").Skill;

pub const ProfessionRow = struct {
    id: Profession.Id,
    name: []const u8,
    icon: Icon.Id,
    description: []const u8,
};

pub const Profession = struct {
    pub const Id = u32;
    pub const Row = ProfessionRow;
    pub const table_name: []const u8 = "professions";
    pub const resource_name: []const u8 = "profession";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    description: []const u8,
    specializations: []Specialization,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !Profession {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;
        const specializations = try db.readSubResource(gpa, Profession, Specialization, row.id);

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
            .description = row.description,
            .specializations = specializations,
        };
    }
};

pub const SpecializationRow = struct {
    id: Specialization.Id,
    profession: Profession.Id,
    name: []const u8,
    description: []const u8,
    heroic_skill: ?Skill.Id,
};

pub const Specialization = struct {
    pub const Id = u32;
    pub const Row = SpecializationRow;
    pub const table_name: []const u8 = "profession_specializations";
    pub const resource_name: []const u8 = "specialization";
    pub const order_by: []const u8 = "id";

    id: Id = 0,
    name: []const u8,
    description: []const u8,
    skills: []Skill,
    heroic_skill: ?Skill,
    items: [][]Item,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !Specialization {
        const skill_rows = try db.readSubResource(gpa, Specialization, SpecializationSkill, row.id);
        const skills = try gpa.alloc(Skill, skill_rows.len);
        for (skill_rows, 0..) |skill_row, i| skills[i] = skill_row.skill;

        const heroic_skill = if (row.heroic_skill) |id|
            (try db.readItem(gpa, Skill, id)) orelse return error.HeroicSkillNotFound
        else
            null;

        const item_rows = try db.readSubResource(gpa, Specialization, SpecializationItem, row.id);
        const items = try packageItems(gpa, item_rows);

        return .{
            .id = row.id,
            .name = row.name,
            .description = row.description,
            .skills = skills,
            .heroic_skill = heroic_skill,
            .items = items,
        };
    }
};

/// One starting skill. Position is stored only to preserve the data's order.
pub const SpecializationSkillRow = struct {
    specialization: Specialization.Id,
    skill: Skill.Id,
    position: u32,
};

pub const SpecializationSkill = struct {
    pub const Row = SpecializationSkillRow;
    pub const table_name: []const u8 = "profession_specialization_skills";
    pub const order_by: []const u8 = "position";

    skill: Skill,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !SpecializationSkill {
        const skill = (try db.readItem(gpa, Skill, row.skill)) orelse return error.SkillNotFound;
        return .{ .skill = skill };
    }
};

/// One item within one selectable starting-gear package. Repeated item ids are
/// allowed because package contents are an ordered list, not a set.
pub const SpecializationItemRow = struct {
    specialization: Specialization.Id,
    package_index: u32,
    position: u32,
    item: Item.Id,
};

pub const SpecializationItem = struct {
    pub const Row = SpecializationItemRow;
    pub const table_name: []const u8 = "profession_specialization_items";
    pub const order_by: []const u8 = "package_index, position";

    package_index: u32,
    item: Item,

    pub fn fromRow(db: anytype, gpa: Allocator, row: Row) !SpecializationItem {
        const item = (try db.readItem(gpa, Item, row.item)) orelse return error.ItemNotFound;
        return .{ .package_index = row.package_index, .item = item };
    }
};

/// Converts the ordered flat join rows into the JSON's ordered packages.
fn packageItems(gpa: Allocator, rows: []const SpecializationItem) ![][]Item {
    if (rows.len == 0) return error.EmptyStartingGear;

    const package_count: usize = @intCast(rows[rows.len - 1].package_index);
    if (package_count == 0) return error.InvalidPackageIndex;

    const packages = try gpa.alloc([]Item, package_count);
    var row_index: usize = 0;
    for (packages, 1..) |*package, package_index| {
        const first = row_index;
        while (row_index < rows.len and rows[row_index].package_index == package_index) : (row_index += 1) {}
        if (row_index == first) return error.MissingStartingGearPackage;

        package.* = try gpa.alloc(Item, row_index - first);
        for (rows[first..row_index], 0..) |item_row, i| package.*[i] = item_row.item;
    }
    if (row_index != rows.len) return error.InvalidPackageIndex;

    return packages;
}

test "Profession serializes the full specialization wire shape" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const icon = Icon{ .id = 1, .name = "anvil" };
    const skill_kind = @import("skill.zig").SkillKind{ .id = 1, .name = "Core", .base_chance = true };
    const skill = Skill{ .id = 2, .name = "Crafting", .icon = icon, .kind = skill_kind, .description = "Make things." };
    const item_kind = @import("item_kind.zig").ItemKind{ .id = 1, .name = "Tool", .icon = icon };
    const supply = @import("item_supply.zig").ItemSupply{ .id = 1, .name = "common", .color = "green" };
    const item = Item{ .id = 3, .name = "Hammer", .icon = icon, .kind = item_kind, .cost = 1, .supply = supply, .weight = 1, .effect = null, .description = "Hits things." };
    const skills = [_]Skill{skill};
    const package = [_]Item{item};
    const packages = [_][]Item{@constCast(&package)};
    const specializations = [_]Specialization{.{
        .id = 4,
        .name = "Default",
        .description = "A maker.",
        .skills = @constCast(&skills),
        .heroic_skill = null,
        .items = @constCast(&packages),
    }};
    const profession = Profession{ .id = 5, .name = "Artisan", .icon = icon, .description = "Makes things.", .specializations = @constCast(&specializations) };

    try std.json.Stringify.value(profession, .{}, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"heroic_skill\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"items\":[[") != null);
}
