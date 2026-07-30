// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

/// Run all sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    const db_dir = try Io.Dir.cwd().openDir(init.io, "db", .{ .iterate = true });
    var db_it = db_dir.iterate();
    while (try db_it.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".sql")) continue;
        std.debug.print("Running migration: {s}\n", .{name});

        var child = try std.process.spawn(init.io, .{ .argv = &.{ "psql", "zttrpg", "-f", name }, .cwd = .{ .dir = db_dir } });
        const term = try child.wait(init.io);
        if (term.exited != 0) {
            return error.MigrationFailed;
        }
    }
}
