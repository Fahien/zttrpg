// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

pub const PGconn = opaque {};
pub extern fn PQconnectdb(conninfo: [*]const u8) ?*PGconn;

pub const PGStatus = enum(u32) {
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1,
};
pub extern fn PQstatus(conn: *PGconn) PGStatus;

pub extern fn PQerrorMessage(conn: *PGconn) [*:0]const u8;

pub extern fn PQfinish(conn: *PGconn) void;

pub const PGresult = opaque {};
pub extern fn PQexec(conn: *PGconn, query: [*:0]const u8) ?*PGresult;

pub const PGExecStatusType = enum(u32) {
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    // >=3 trouble
};
pub extern fn PQresultStatus(res: *PGresult) PGExecStatusType;

pub extern fn PQclear(res: *PGresult) void;
