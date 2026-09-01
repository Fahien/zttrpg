// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! The server loop: accept a connection, read one request, hand it to a
//! handler, close. What each route means lives in route.zig, what each handler
//! does in handler.zig, and how pages are assembled in page.zig.

const std = @import("std");
const zttrpg = @import("zttrpg");

const context = @import("context.zig");
const handler = @import("handler.zig");
const page = @import("page.zig");
const route = @import("route.zig");
const locked = @import("locked.zig");

const Context = context.Context;
const Route = route.Route;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const address = "127.0.0.1";
const port = 8080;

/// Each connection reads its request into a buffer of this size.
const connection_buffer_size = 4096;

/// Create our own ceiling to be able to accept multiple connections.
const max_connections_in_flight = 64;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.log.info("ZTTRPG", .{});

    const db = try zttrpg.Database.init();
    defer db.deinit();

    var threaded: Io.Threaded = .init(init.gpa, .{
        .concurrent_limit = .limited(max_connections_in_flight),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const ip_address = try Io.net.IpAddress.parse(address, port);
    var server = try ip_address.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer server.deinit(io);

    std.log.info("Listening on http://{s}:{d}", .{ address, port });

    var connections: Io.Group = .init;
    defer connections.cancel(io);

    while (true) {
        const conn = try server.accept(io);

        connections.concurrent(io, serveConnection, .{ init.gpa, io, conn, &db }) catch |err| {
            respondStatus(io, conn, std.http.Status.service_unavailable) catch |status_err| {
                std.log.err("Error responding to connection: {}", .{status_err});
            };

            std.log.err("Refusing connection: {}", .{err});
            conn.close(io);
        };
    }
}

pub fn respondStatus(
    io: Io,
    conn: Io.net.Stream,
    status: std.http.Status,
) !void {
    var write_buffer: [256]u8 = undefined;
    var conn_writer = Io.net.Stream.Writer.init(conn, io, &write_buffer);
    const phrase = status.phrase() orelse "";
    try conn_writer.interface.print("HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ @intFromEnum(status), phrase });
    try conn_writer.interface.flush();
}

fn serveConnection(gpa: Allocator, io: Io, conn: Io.net.Stream, db: *const zttrpg.Database) void {
    defer conn.close(io);

    // One bad request must not take the server down with it.
    handleConnection(gpa, io, conn, db) catch |err| {
        std.log.err("Error handling connection: {}", .{err});
    };
}

fn handleConnection(
    gpa: Allocator,
    io: Io,
    conn: Io.net.Stream,
    db: *const zttrpg.Database,
) !void {
    std.log.info("Accepted connection from {d}.{d}.{d}.{d}:{d}", .{
        conn.socket.address.ip4.bytes[0],
        conn.socket.address.ip4.bytes[1],
        conn.socket.address.ip4.bytes[2],
        conn.socket.address.ip4.bytes[3],
        conn.socket.address.getPort(),
    });

    // Everything this request allocates comes from here and is released in one
    // go when the connection closes, which is why nothing downstream frees.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const arena_gpa = arena.allocator();

    const read_buffer = try arena_gpa.alloc(u8, connection_buffer_size);
    const write_buffer = try arena_gpa.alloc(u8, connection_buffer_size);

    var conn_reader = Io.net.Stream.Reader.init(conn, io, read_buffer);
    var conn_writer = Io.net.Stream.Writer.init(conn, io, write_buffer);

    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var request = try http_server.receiveHead();

    // Logged here because reading a body invalidates head.target: see
    // Context.respondError.
    std.log.debug("Received request: {} {s}", .{ request.head.method, request.head.target });

    var ctx = Context.init(arena_gpa, io, db, &request);

    try handler.dispatch(&ctx, Route.parseRoute(request.head.target));
}

test {
    // Test discovery is lazy: a file's tests are collected only when the file
    // is referenced from a test context, so name every file this module owns.
    _ = context;
    _ = handler;
    _ = page;
    _ = route;
    _ = locked;
}
