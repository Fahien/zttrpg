// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const zttrpg = @import("zttrpg");
const pq = @import("pq");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("ZTTRPG\n", .{});

    const db = try zttrpg.Database.init();
    defer db.deinit();

    const characters = try db.readCharactersAlloc(init.gpa);
    defer {
        for (characters) |character| {
            character.deinit();
        }
        init.gpa.free(characters);
    }

    std.debug.print("Characters:\n", .{});
    for (characters) |character| {
        std.debug.print("  - {s} (level {d})\n", .{ character.name, character.level });
    }
}
