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
    std.debug.print("Accepted connection from {d}.{d}.{d}.{d}:{d}\n", .{
        conn.socket.address.ip4.bytes[0],
        conn.socket.address.ip4.bytes[1],
        conn.socket.address.ip4.bytes[2],
        conn.socket.address.ip4.bytes[3],
        conn.socket.address.getPort(),
    });

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

    var writer = Io.Writer.Allocating.init(gpa);

    if (std.mem.eql(u8, request.head.target, "/")) {
        try writer.writer.print("ZTTRPG\n", .{});
        try request.respond(writer.written(), .{ .keep_alive = false });
    } else if (std.mem.eql(u8, request.head.target, "/characters")) {
        try handleCharacters(gpa, &writer, db, &request);
    } else {
        try writer.writer.print("404 Not Found\n", .{});
        try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
    }
}

fn handleCharacters(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    switch (request.head.method) {
        .GET => try respondCharacters(gpa, writer, db, request),
        .POST => try insertCharacter(gpa, writer, db, request),
        else => |method| {
            try writer.writer.print("Method {} not allowed.\n", .{method});
            try request.respond(writer.written(), .{ .status = .method_not_allowed, .keep_alive = false });
        },
    }
}

fn respondCharacters(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    const characters = try db.readCharactersAlloc(gpa);

    try writer.writer.print("Characters:\n", .{});
    for (characters) |character| {
        try writer.writer.print("  - {d}: {s} (level {d})\n", .{
            character.id,
            character.name,
            character.level,
        });
    }
    try request.respond(writer.written(), .{ .keep_alive = false });
}

fn insertCharacter(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    const scratch_buffer = try gpa.alloc(u8, 4096);
    const reader = try request.readerExpectContinue(scratch_buffer);
    const body = try reader.allocRemaining(gpa, .limited(4096));

    const character = std.json.parseFromSliceLeaky(
        zttrpg.CreateCharacter,
        gpa,
        body,
        .{},
    ) catch {
        try writer.writer.print("Invalid JSON body.\n", .{});
        try request.respond(writer.written(), .{ .status = .bad_request, .keep_alive = false });
        return;
    };

    db.insertCharacter(gpa, character) catch {
        try writer.writer.print("Failed to insert character.\n", .{});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    std.debug.print("Inserted character: {s} (level {d})\n", .{ character.name, character.level });

    try writer.writer.print("OK\n", .{});
    try request.respond(writer.written(), .{ .status = .created, .keep_alive = false });
}
