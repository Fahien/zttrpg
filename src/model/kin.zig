// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kin = struct {
    pub const table_name: []const u8 = "kins";

    id: u32 = 0,
    name: []const u8,

    pub fn init(gpa: Allocator, id: u32, name: []const u8) !Kin {
        const name_copy = try gpa.dupe(u8, name);
        return Kin{
            .id = id,
            .name = name_copy,
        };
    }

    pub fn deinit(self: *const Kin, gpa: Allocator) void {
        gpa.free(self.name);
    }
};
