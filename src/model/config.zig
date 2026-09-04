// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    pub const Id = u32;
    pub const table_name: []const u8 = "configs";
    pub const attribute_default: []const u8 = "attribute_default";
    pub const attribute_max: []const u8 = "attribute_max";

    id: Id = 0,
    name: []const u8,
    value: []const u8,
};
