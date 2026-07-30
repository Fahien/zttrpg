// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

const pq = @import("pq.zig");

/// Run all sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    const conn = pq.PQconnectdb("dbname=zttrpg") orelse return error.ConnectionFailed;
    defer pq.PQfinish(conn);
    if (pq.PQstatus(conn) != pq.PGStatus.CONNECTION_OK) {
        const err = pq.PQerrorMessage(conn);
        std.debug.print("Connection failed: {s}\n", .{err});
        return error.ConnectionFailed;
    }

    // Create schema_migrations if it doesn't exist
    const create_schema_migrations_sql = "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)";
    const schema_migration_result = pq.PQexec(conn, create_schema_migrations_sql) orelse return error.ExecutionFailed;
    defer pq.PQclear(schema_migration_result);
    if (pq.PQresultStatus(schema_migration_result) != pq.PGExecStatusType.PGRES_COMMAND_OK) {
        const err = pq.PQerrorMessage(conn);
        std.debug.print("Execution failed: {s}\n", .{err});
        return error.ExecutionFailed;
    }

    // Get list of already applied migrations.
    const applied_migrations_sql = "SELECT version FROM schema_migrations";
    const applied_migrations_result = pq.PQexec(conn, applied_migrations_sql) orelse return error.ExecutionFailed;
    defer pq.PQclear(applied_migrations_result);
    if (pq.PQresultStatus(applied_migrations_result) != pq.PGExecStatusType.PGRES_TUPLES_OK) {
        const err = pq.PQerrorMessage(conn);
        std.debug.print("Execution failed: {s}\n", .{err});
        return error.ExecutionFailed;
    }

    var applied_migrations = std.StringHashMap(void).init(init.gpa);
    defer applied_migrations.deinit();
    const tuple_count = pq.PQntuples(applied_migrations_result);
    for (0..@intCast(tuple_count)) |i| {
        const version_cstr = pq.PQgetvalue(applied_migrations_result, @intCast(i), 0);
        const version_str = std.mem.span(version_cstr);

        try applied_migrations.put(version_str, {});
    }

    const db_dir = try Io.Dir.cwd().openDir(init.io, "db", .{ .iterate = true });
    var db_it = db_dir.iterate();
    while (try db_it.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".sql")) continue;

        if (applied_migrations.contains(name)) {
            std.debug.print("Skipping already applied migration: {s}\n", .{name});
            continue;
        }

        std.debug.print("Running migration: {s}\n", .{name});

        const sql_str = try std.Io.Dir.readFileAlloc(db_dir, init.io, name, init.gpa, .unlimited);
        defer init.gpa.free(sql_str);
        const sql_cstr = try init.gpa.dupeZ(u8, sql_str);
        defer init.gpa.free(sql_cstr);

        const result = pq.PQexec(conn, sql_cstr) orelse return error.ExecutionFailed;
        defer pq.PQclear(result);

        const status = pq.PQresultStatus(result);
        if (status != pq.PGExecStatusType.PGRES_COMMAND_OK and status != pq.PGExecStatusType.PGRES_TUPLES_OK) {
            const err = pq.PQerrorMessage(conn);
            std.debug.print("Execution failed: {s}\n", .{err});
            return error.ExecutionFailed;
        }

        const insert_migration_sql = "INSERT INTO schema_migrations (version) VALUES ('{s}')";
        const insert_migration_sql_fmt = try std.fmt.allocPrintSentinel(init.gpa, insert_migration_sql, .{name}, 0);
        defer init.gpa.free(insert_migration_sql_fmt);
        const insert_result = pq.PQexec(conn, insert_migration_sql_fmt) orelse return error.ExecutionFailed;
        defer pq.PQclear(insert_result);
        if (pq.PQresultStatus(insert_result) != pq.PGExecStatusType.PGRES_COMMAND_OK) {
            const err = pq.PQerrorMessage(conn);
            std.debug.print("Execution failed: {s}\n", .{err});
            return error.ExecutionFailed;
        }
    }
}
