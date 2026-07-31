// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

const pq = @import("pq.zig");

/// Run all sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    const conn = try pq.Connection.connect("dbname=zttrpg");
    defer conn.close();

    // Create schema_migrations if it doesn't exist
    const create_schema_migrations_sql = "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)";
    const schema_migration_result = try conn.exec(create_schema_migrations_sql);
    defer schema_migration_result.deinit();

    // Get list of already applied migrations.
    const applied_migrations_sql = "SELECT version FROM schema_migrations";
    const applied_migrations_result = try conn.exec(applied_migrations_sql);
    defer applied_migrations_result.deinit();

    var applied_migrations = std.StringHashMap(void).init(init.gpa);
    defer applied_migrations.deinit();
    const tuple_count = applied_migrations_result.len();
    for (0..@intCast(tuple_count)) |i| {
        const version_cstr = applied_migrations_result.getValue(@intCast(i), 0);
        const version_str = std.mem.span(version_cstr);

        try applied_migrations.put(version_str, {});
    }

    // SQL file names will be collected into a list and sorted.
    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |name| {
            init.gpa.free(name);
        }
        names.deinit(init.gpa);
    }

    // Collect all .sql files in the db directory.
    const db_dir = try Io.Dir.cwd().openDir(init.io, "db", .{ .iterate = true });
    var db_it = db_dir.iterate();
    while (try db_it.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".sql")) continue;

        const name_copy = try init.gpa.dupe(u8, name);
        errdefer init.gpa.free(name_copy);
        try names.append(init.gpa, name_copy);
    }

    // Sort the names of the SQL files to ensure they are applied in order.
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    for (names.items) |name| {
        if (applied_migrations.contains(name)) {
            std.debug.print("Skipping already applied migration: {s}\n", .{name});
            continue;
        }

        std.debug.print("Running migration: {s}\n", .{name});

        const sql_str = try std.Io.Dir.readFileAlloc(db_dir, init.io, name, init.gpa, .unlimited);
        defer init.gpa.free(sql_str);
        const sql_cstr = try init.gpa.dupeZ(u8, sql_str);
        defer init.gpa.free(sql_cstr);

        try conn.beginTransaction();

        const result = try conn.exec(sql_cstr);
        defer result.deinit();

        const insert_migration_sql = "INSERT INTO schema_migrations (version) VALUES ($1)";

        const name_cstr = try init.gpa.dupeZ(u8, name);
        defer init.gpa.free(name_cstr);

        const insert_result = try conn.execParams(insert_migration_sql, &.{name_cstr.ptr});
        defer insert_result.deinit();

        try conn.commitTransaction();
    }
}

/// Sorts byte strings lexicographically.
fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
