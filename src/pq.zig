// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const PGconn = opaque {};
extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;

pub const PGStatus = enum(u32) {
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1,
    _,
};
extern fn PQstatus(conn: *PGconn) PGStatus;

extern fn PQerrorMessage(conn: *PGconn) [*:0]const u8;

extern fn PQfinish(conn: *PGconn) void;

const PGresult = opaque {};
extern fn PQexec(conn: *PGconn, query: [*:0]const u8) ?*PGresult;
extern fn PQexecParams(conn: *PGconn, query: ?[*:0]const u8, nParams: c_int, paramTypes: ?[*]const u32, paramValues: ?[*]const ?[*:0]const u8, paramLengths: ?[*]const c_int, paramFormats: ?[*]const c_int, resultFormat: c_int) ?*PGresult;

pub const PGExecStatusType = enum(u32) {
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    // >=3 trouble
    PGRES_FATAL_ERROR = 7,
    _,
};
extern fn PQresultStatus(res: *PGresult) PGExecStatusType;

extern fn PQclear(res: *PGresult) void;

extern fn PQntuples(res: *PGresult) c_int;

extern fn PQgetvalue(res: *PGresult, row: c_int, col: c_int) [*:0]const u8;

extern fn PQcmdTuples(res: *PGresult) [*:0]const u8;

/// Field code for PQresultErrorField, from postgres_ext.h.
const PG_DIAG_SQLSTATE: c_int = 'C';
extern fn PQresultErrorField(res: *PGresult, fieldcode: c_int) ?[*:0]const u8;

pub const Connection = struct {
    conn: *PGconn,

    pub fn connect(conninfo: [*:0]const u8) !Connection {
        const conn = PQconnectdb(conninfo) orelse return error.PqConnectionFailed;
        if (PQstatus(conn) != PGStatus.CONNECTION_OK) {
            const err = PQerrorMessage(conn);
            std.debug.print("Connection failed: {s}\n", .{err});
            return error.PqConnectionFailed;
        }
        return Connection{ .conn = conn };
    }

    pub fn status(self: *const Connection) PGStatus {
        return PQstatus(self.conn);
    }

    pub fn errorMessage(self: *const Connection) [*:0]const u8 {
        return PQerrorMessage(self.conn);
    }

    pub fn exec(self: *const Connection, query: [*:0]const u8) !Result {
        const res = PQexec(self.conn, query) orelse return error.PqExecutionFailed;
        return try Result.init(self.conn, res);
    }

    pub fn execParams(
        self: *const Connection,
        query: [*:0]const u8,
        params: []const [*:0]const u8,
    ) !Result {
        const res = PQexecParams(
            self.conn,
            query,
            @intCast(params.len),
            null,
            params.ptr,
            null,
            null,
            0,
        ) orelse return error.PqExecutionFailed;

        return try Result.init(self.conn, res);
    }

    pub fn close(self: *const Connection) void {
        PQfinish(self.conn);
    }

    pub fn beginTransaction(self: *const Connection) !void {
        const res = try self.exec("BEGIN");
        defer res.deinit();
    }

    pub fn commitTransaction(self: *const Connection) !void {
        const res = try self.exec("COMMIT");
        defer res.deinit();
    }

    pub fn rollbackTransaction(self: *const Connection) !void {
        const res = try self.exec("ROLLBACK");
        defer res.deinit();
    }
};

/// What a failed command can report. The named variants are the integrity
/// violations a client can provoke, so the layer above can answer 4xx instead
/// of blaming itself with a 500; anything else stays PqResultError.
pub const ResultError = error{
    UniqueViolation,
    ForeignKeyViolation,
    NotNullViolation,
    CheckViolation,
    PqResultError,
};

/// SQLSTATE codes are five characters and stable across Postgres versions,
/// which is what makes them safe to branch on -- the message text is not.
/// Class 23 is "integrity constraint violation".
const sqlstate_errors = .{
    .{ "23502", ResultError.NotNullViolation },
    .{ "23503", ResultError.ForeignKeyViolation },
    .{ "23505", ResultError.UniqueViolation },
    .{ "23514", ResultError.CheckViolation },
};

/// Maps a SQLSTATE to the error the caller sees. An unlisted code is not a
/// failure of this function: it means nothing above cares to tell that failure
/// apart from any other, so it collapses into PqResultError.
fn errorFromSqlState(code: []const u8) ResultError {
    inline for (sqlstate_errors) |entry| {
        if (std.mem.eql(u8, code, entry[0])) return entry[1];
    }
    return ResultError.PqResultError;
}

pub const Result = struct {
    res: *PGresult,

    /// Reads the SQLSTATE attached to this result, or null when there is none
    /// (a successful command, or a failure that never reached the server).
    pub fn sqlState(self: *const Result) ?[]const u8 {
        const code = PQresultErrorField(self.res, PG_DIAG_SQLSTATE) orelse return null;
        return std.mem.span(code);
    }

    fn check(conn: *PGconn, res: *PGresult) ResultError!void {
        const exec_status = PQresultStatus(res);
        if (exec_status == PGExecStatusType.PGRES_COMMAND_OK or
            exec_status == PGExecStatusType.PGRES_TUPLES_OK)
        {
            return;
        }

        const err = PQerrorMessage(conn);
        const sqlstate = PQresultErrorField(res, PG_DIAG_SQLSTATE);
        std.debug.print("PQ error [{s}]: {s}\n", .{ sqlstate orelse "-----", err });

        if (sqlstate) |code| {
            return errorFromSqlState(std.mem.span(code));
        }
        return ResultError.PqResultError;
    }

    fn init(conn: *PGconn, res: *PGresult) !Result {
        // A failed result still owns memory: clearing it here means neither
        // caller of init has to unwind a result it never received.
        errdefer PQclear(res);
        try Result.check(conn, res);
        return Result{ .res = res };
    }

    pub fn deinit(self: *const Result) void {
        PQclear(self.res);
    }

    pub fn status(self: *const Result) PGExecStatusType {
        return PQresultStatus(self.res);
    }

    pub fn len(self: *const Result) usize {
        return @intCast(PQntuples(self.res));
    }

    pub fn getValue(self: *const Result, row: usize, col: usize) [*:0]const u8 {
        return PQgetvalue(self.res, @intCast(row), @intCast(col));
    }

    pub fn affectedRows(self: *const Result) !usize {
        const row_count_cstr = PQcmdTuples(self.res);
        const row_count = std.mem.span(row_count_cstr);
        return try std.fmt.parseInt(usize, row_count, 10);
    }
};

test "errorFromSqlState names the violations a client can provoke" {
    // A duplicate character name is the one that motivated this: without the
    // code it looks exactly like a server fault and answers 500.
    try std.testing.expectEqual(ResultError.UniqueViolation, errorFromSqlState("23505"));
    try std.testing.expectEqual(ResultError.ForeignKeyViolation, errorFromSqlState("23503"));
    try std.testing.expectEqual(ResultError.NotNullViolation, errorFromSqlState("23502"));
    try std.testing.expectEqual(ResultError.CheckViolation, errorFromSqlState("23514"));
}

test "errorFromSqlState collapses codes nothing above distinguishes" {
    // 40001 is a serialization failure and 42P01 an undefined table: both are
    // real, neither has a distinct answer at the HTTP layer today.
    try std.testing.expectEqual(ResultError.PqResultError, errorFromSqlState("40001"));
    try std.testing.expectEqual(ResultError.PqResultError, errorFromSqlState("42P01"));
    // Not a code at all.
    try std.testing.expectEqual(ResultError.PqResultError, errorFromSqlState(""));
}
