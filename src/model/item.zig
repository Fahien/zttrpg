// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;
const ItemKind = @import("item_kind.zig").ItemKind;
const ItemSupply = @import("item_supply.zig").ItemSupply;
const Database = @import("../database.zig").Database;

pub const ItemBody = struct {
    name: []const u8,
    icon: Icon.Id,
    kind: ItemKind.Id,
    cost: u32,
    supply: ItemSupply.Id,
    weight: f64 = 1.0,
    effect: ?[]const u8 = null,
    description: []const u8,

    // Mirrors the items table's CHECK constraints. `cost` is unsigned, so a
    // negative JSON cost is rejected while parsing before it reaches here.
    pub fn validate(self: *const ItemBody) error{ EmptyName, WeightOutOfRange, EmptyDescription }!void {
        if (self.name.len == 0) return error.EmptyName;
        if (!std.math.isFinite(self.weight) or self.weight < 0.0) return error.WeightOutOfRange;
        if (self.description.len == 0) return error.EmptyDescription;
    }
};

pub const ItemCreate = ItemBody;
pub const ItemUpdate = ItemBody;

/// The flat SQL shape: foreign keys are IDs until fromRow resolves them.
pub const ItemRow = struct {
    id: Item.Id,
    name: []const u8,
    icon: Icon.Id,
    kind: ItemKind.Id,
    cost: u32,
    supply: ItemSupply.Id,
    weight: f64,
    effect: ?[]const u8,
    description: []const u8,
};

pub const Item = struct {
    pub const Id = u32;
    pub const Create = ItemCreate;
    pub const Update = ItemUpdate;
    pub const Row = ItemRow;
    pub const table_name: []const u8 = "items";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    kind: ItemKind,
    cost: u32,
    supply: ItemSupply,
    weight: f64,
    effect: ?[]const u8,
    description: []const u8,

    pub fn fromRow(db: *const Database, gpa: Allocator, row: Row) !Item {
        const icon = (try db.readItem(gpa, Icon, row.icon)) orelse return error.IconNotFound;
        const kind = (try db.readItem(gpa, ItemKind, row.kind)) orelse return error.ItemKindNotFound;
        const supply = (try db.readItem(gpa, ItemSupply, row.supply)) orelse return error.ItemSupplyNotFound;

        return .{
            .id = row.id,
            .name = row.name,
            .icon = icon,
            .kind = kind,
            .cost = row.cost,
            .supply = supply,
            .weight = row.weight,
            .effect = row.effect,
            .description = row.description,
        };
    }
};

test "ItemCreate.validate accepts a well-formed item" {
    const item = ItemCreate{ .name = "Ration", .icon = 1, .kind = 1, .cost = 10, .supply = 1, .description = "One day's food." };
    try item.validate();
}

test "ItemCreate.validate rejects fields prohibited by item checks" {
    const empty_name = ItemCreate{ .name = "", .icon = 1, .kind = 1, .cost = 0, .supply = 1, .description = "Food." };
    try std.testing.expectError(error.EmptyName, empty_name.validate());

    const negative_weight = ItemCreate{ .name = "Ration", .icon = 1, .kind = 1, .cost = 0, .supply = 1, .weight = -0.25, .description = "Food." };
    try std.testing.expectError(error.WeightOutOfRange, negative_weight.validate());

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |weight| {
        const non_finite_weight = ItemCreate{ .name = "Ration", .icon = 1, .kind = 1, .cost = 0, .supply = 1, .weight = weight, .description = "Food." };
        try std.testing.expectError(error.WeightOutOfRange, non_finite_weight.validate());
    }

    const empty_description = ItemCreate{ .name = "Ration", .icon = 1, .kind = 1, .cost = 0, .supply = 1, .description = "" };
    try std.testing.expectError(error.EmptyDescription, empty_description.validate());
}

test "ItemCreate JSON defaults optional item values" {
    const parsed = try std.json.parseFromSlice(
        ItemCreate,
        std.testing.allocator,
        \\{"name":"Ration","icon":1,"kind":1,"cost":10,"supply":1,"description":"One day's food."}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(f64, 1.0), parsed.value.weight);
    try std.testing.expect(parsed.value.effect == null);
}

test "ItemCreate validation rejects a weight that overflows JSON f64" {
    const parsed = try std.json.parseFromSlice(
        ItemCreate,
        std.testing.allocator,
        \\{"name":"Ration","icon":1,"kind":1,"cost":10,"supply":1,"weight":1e9999,"description":"One day's food."}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(error.WeightOutOfRange, parsed.value.validate());
}

test "Item serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const icon = Icon{ .id = 1, .name = "bread" };
    const item = Item{
        .id = 1,
        .name = "Ration",
        .icon = icon,
        .kind = ItemKind{ .id = 1, .name = "Food", .icon = icon },
        .cost = 10,
        .supply = ItemSupply{ .id = 1, .name = "common", .color = "green" },
        .weight = 0.25,
        .effect = null,
        .description = "One day's food.",
    };
    try std.json.Stringify.value(item, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Ration","icon":{"id":1,"name":"bread"},"kind":{"id":1,"name":"Food","icon":{"id":1,"name":"bread"}},"cost":10,"supply":{"id":1,"name":"common","color":"green"},"weight":0.25,"effect":null,"description":"One day's food."}
    , out.written());
}
