// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const zttrpg = @import("zttrpg");
const pq = @import("pq");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("ZTTRPG\n", .{});

    const db = try zttrpg.Database.init();
    defer db.deinit();

    // TCP skeleton.
    const address = "127.0.0.1";
    const port = 8080;

    const ip_address = try Io.net.IpAddress.parse(address, port);
    var server = try ip_address.listen(init.io, .{ .mode = .stream });
    defer server.deinit(init.io);

    while (true) {
        const conn = try server.accept(init.io);
        defer conn.close(init.io);

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
    std.debug.print("Accepted connection from {s}:{d}\n", .{ conn.socket.address.ip4.bytes, conn.socket.address.getPort() });

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const gpa = arena.allocator();

    const read_buffer = try gpa.alloc(u8, 4096);
    const write_buffer = try gpa.alloc(u8, 4096);

    var conn_reader = Io.net.Stream.Reader.init(conn, init.io, read_buffer);
    var conn_writer = Io.net.Stream.Writer.init(conn, init.io, write_buffer);

    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var request = try http_server.receiveHead();

    std.debug.print("Received request: {} {s}\n", .{ request.head.method, request.head.target });

    var allocating_writer = Io.Writer.Allocating.init(gpa);

    if (std.mem.eql(u8, request.head.target, "/")) {
        try allocating_writer.writer.print("ZTTRPG\n", .{});
        try request.respond(allocating_writer.written(), .{});
    } else if (std.mem.eql(u8, request.head.target, "/characters")) {
        try writeCharactersResponse(gpa, &allocating_writer, db, &request);
    } else {
        try allocating_writer.writer.print("404 Not Found\n", .{});
        try request.respond(allocating_writer.written(), .{ .status = .not_found });
    }
}

fn writeCharactersResponse(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    const characters = try db.readCharactersAlloc(gpa);

    try writer.writer.print("Characters:\n", .{});
    for (characters) |character| {
        try writer.writer.print("  - {s} (level {d})\n", .{ character.name, character.level });
    }
    try request.respond(writer.written(), .{});
}
