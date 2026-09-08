// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;

pub const ItemSupplyBody = struct {
    name: []const u8,
    color: []const u8,

    // Mirrors the item_supplies table's CHECK constraints: the database
    // enforces integrity, this gives clients a 400 instead of a 500.
    pub fn validate(self: *const ItemSupplyBody) error{ EmptyName, EmptyValue }!void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.color.len == 0) return error.EmptyValue;
    }
};

pub const ItemSupplyCreate = ItemSupplyBody;
pub const ItemSupplyUpdate = ItemSupplyBody;

pub const ItemSupply = struct {
    pub const Id = u32;
    pub const Create = ItemSupplyCreate;
    pub const Update = ItemSupplyUpdate;
    pub const table_name: []const u8 = "item_supplies";

    id: Id = 0,
    name: []const u8,
    color: []const u8,
};
