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

const Context = context.Context;
const Route = route.Route;

const Io = std.Io;

const address = "127.0.0.1";
const port = 8080;

/// Each connection reads its request into a buffer of this size.
const connection_buffer_size = 4096;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("ZTTRPG\n", .{});

    const db = try zttrpg.Database.init();
    defer db.deinit();

    const ip_address = try Io.net.IpAddress.parse(address, port);
    var server = try ip_address.listen(init.io, .{ .mode = .stream, .reuse_address = true });
    defer server.deinit(init.io);

    std.debug.print("Listening on http://{s}:{d}\n", .{ address, port });

    while (true) {
        const conn = try server.accept(init.io);
        defer conn.close(init.io);

        // One bad request must not take the server down with it.
        handleConnection(init, conn, &db) catch |err| {
            std.debug.print("Error handling connection: {}\n", .{err});
        };
    }
}

fn handleConnection(
    init: std.process.Init,
    conn: Io.net.Stream,
    db: *const zttrpg.Database,
) !void {
    std.debug.print("Accepted connection from {d}.{d}.{d}.{d}:{d}\n", .{
        conn.socket.address.ip4.bytes[0],
        conn.socket.address.ip4.bytes[1],
        conn.socket.address.ip4.bytes[2],
        conn.socket.address.ip4.bytes[3],
        conn.socket.address.getPort(),
    });

    // Everything this request allocates comes from here and is released in one
    // go when the connection closes, which is why nothing downstream frees.
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const gpa = arena.allocator();

    const read_buffer = try gpa.alloc(u8, connection_buffer_size);
    const write_buffer = try gpa.alloc(u8, connection_buffer_size);

    var conn_reader = Io.net.Stream.Reader.init(conn, init.io, read_buffer);
    var conn_writer = Io.net.Stream.Writer.init(conn, init.io, write_buffer);

    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var request = try http_server.receiveHead();

    // Logged here because reading a body invalidates head.target: see
    // Context.respondError.
    std.debug.print("Received request: {} {s}\n", .{ request.head.method, request.head.target });

    var ctx = Context.init(gpa, init.io, db, &request);

    try handler.dispatch(&ctx, Route.parseRoute(request.head.target));
}

test {
    // Test discovery is lazy: a file's tests are collected only when the file
    // is referenced from a test context, so name every file this module owns.
    _ = context;
    _ = handler;
    _ = page;
    _ = route;
}
