// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const pq = @import("pq");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Character = struct {
    name: []const u8,
    level: u32,

    pub fn init(gpa: Allocator, name: []const u8, level: u32) !Character {
        const name_copy = try gpa.dupe(u8, name);
        return Character{
            .name = name_copy,
            .level = level,
        };
    }

    pub fn deinit(self: *const Character, gpa: Allocator) void {
        gpa.free(self.name);
    }
};

pub const Database = struct {
    conn: pq.Connection,

    pub fn init() !Database {
        const conn = try pq.Connection.connect("dbname=zttrpg");
        return Database{
            .conn = conn,
        };
    }

    pub fn deinit(self: *const Database) void {
        self.conn.close();
    }

    pub fn readCharactersAlloc(self: *const Database, gpa: Allocator) ![]Character {
        const result = try self.conn.exec("SELECT name, level FROM characters");
        defer result.deinit();

        const count = result.len();
        var characters = try gpa.alloc(Character, count);

        for (0..count) |i| {
            const name_cstr = result.getValue(i, 0);
            const level_cstr = result.getValue(i, 1);

            const name_str = std.mem.span(name_cstr);
            const level_str = std.mem.span(level_cstr);

            const level = try std.fmt.parseInt(u32, level_str, 10);

            characters[i] = try Character.init(gpa, name_str, level);
        }

        return characters;
    }
};
