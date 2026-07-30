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

    const db_dir = try Io.Dir.cwd().openDir(init.io, "db", .{ .iterate = true });
    var db_it = db_dir.iterate();
    while (try db_it.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".sql")) continue;
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
    }
}
