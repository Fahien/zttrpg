// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const PGconn = opaque {};
extern fn PQconnectdb(conninfo: [*]const u8) ?*PGconn;

pub const PGStatus = enum(u32) {
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1,
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
};
extern fn PQresultStatus(res: *PGresult) PGExecStatusType;

extern fn PQclear(res: *PGresult) void;

extern fn PQntuples(res: *PGresult) c_int;

extern fn PQgetvalue(res: *PGresult, row: c_int, col: c_int) [*:0]const u8;

pub const Connection = struct {
    conn: *PGconn,

    pub fn connect(conninfo: [*]const u8) !Connection {
        const conn = PQconnectdb(conninfo) orelse return error.ConnectionFailed;
        if (PQstatus(conn) != PGStatus.CONNECTION_OK) {
            const err = PQerrorMessage(conn);
            std.debug.print("Connection failed: {s}\n", .{err});
            return error.ConnectionFailed;
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
        const res = PQexec(self.conn, query) orelse return error.ExecutionFailed;
        if (PQresultStatus(res) != PGExecStatusType.PGRES_COMMAND_OK and
            PQresultStatus(res) != PGExecStatusType.PGRES_TUPLES_OK)
        {
            const err = PQerrorMessage(self.conn);
            std.debug.print("Execution failed: {s}\n", .{err});
            PQclear(res);
            return error.ExecutionFailed;
        }
        return Result.init(res);
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
        ) orelse return error.ExecutionFailed;
        if (PQresultStatus(res) != PGExecStatusType.PGRES_COMMAND_OK and
            PQresultStatus(res) != PGExecStatusType.PGRES_TUPLES_OK)
        {
            const err = PQerrorMessage(self.conn);
            std.debug.print("Execution failed: {s}\n", .{err});
            PQclear(res);
            return error.ExecutionFailed;
        }
        return Result.init(res);
    }

    pub fn close(self: *const Connection) void {
        PQfinish(self.conn);
    }
};

pub const Result = struct {
    res: *PGresult,

    fn init(self: *PGresult) Result {
        return Result{ .res = self };
    }

    pub fn deinit(self: *const Result) void {
        PQclear(self.res);
    }

    pub fn status(self: *const Result) PGExecStatusType {
        return PQresultStatus(self.res);
    }

    pub fn len(self: *const Result) c_int {
        return PQntuples(self.res);
    }

    pub fn getValue(self: *const Result, row: c_int, col: c_int) [*:0]const u8 {
        return PQgetvalue(self.res, row, col);
    }
};
