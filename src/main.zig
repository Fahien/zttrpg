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

    const target = std.mem.trim(u8, request.head.target, "/");

    var path_and_query = std.mem.splitScalar(u8, target, '?');

    const path = path_and_query.next() orelse {
        try writer.writer.print("400 Bad Request: Missing path\n", .{});
        try request.respond(writer.written(), .{ .status = .bad_request, .keep_alive = false });
        return;
    };

    // TODO: use query later.
    _ = path_and_query.next();

    var sequence = std.mem.splitScalar(u8, path, '/');

    const maybe_first_segment = sequence.peek();

    if (maybe_first_segment == null or std.mem.eql(u8, maybe_first_segment.?, "")) {
        try handleRoot(&writer, &request);
    } else {
        const first_segment = sequence.next() orelse unreachable;
        if (std.mem.eql(u8, first_segment, "characters")) {
            try handleCharacters(gpa, &writer, db, &request, &sequence);
        } else {
            try writer.writer.print("404 Not Found: {s}\n", .{first_segment});
            try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
        }
    }
}

fn handleRoot(writer: *Io.Writer.Allocating, request: *std.http.Server.Request) !void {
    try writer.writer.print("ZTTRPG API\n", .{});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false });
}

fn handleCharacters(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    sequence: *std.mem.SplitIterator(u8, .scalar),
) !void {
    const maybe_next_segment = sequence.peek();

    if (maybe_next_segment == null) {
        switch (request.head.method) {
            .GET => try respondCharacters(gpa, writer, db, request),
            .POST => try insertCharacter(gpa, writer, db, request),
            else => |method| {
                try writer.writer.print("Method {} not allowed for this path.\n", .{method});
                try request.respond(writer.written(), .{ .status = .method_not_allowed, .keep_alive = false });
            },
        }
    } else {
        const next_segment = sequence.next() orelse unreachable;

        const id = std.fmt.parseInt(u32, next_segment, 10) catch {
            try writer.writer.print("404 Not Found\n", .{});
            try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
            return;
        };

        const maybe_next_after_id = sequence.peek();
        if (maybe_next_after_id != null) {
            try writer.writer.print("404 Not Found\n", .{});
            try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
            return;
        }

        switch (request.head.method) {
            .GET => try respondCharacter(gpa, writer, db, request, id),
            .DELETE => try deleteCharacter(gpa, writer, db, request, id),
            .PUT => try updateCharacter(gpa, writer, db, request, id),
            else => |method| {
                try writer.writer.print("Method {} not allowed for this path.\n", .{method});
                try request.respond(writer.written(), .{ .status = .method_not_allowed, .keep_alive = false });
            },
        }
    }
}

fn updateCharacter(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    id: u32,
) !void {
    const scratch_buffer = try gpa.alloc(u8, 4096);
    const reader = try request.readerExpectContinue(scratch_buffer);
    const body = try reader.allocRemaining(gpa, .limited(4096));

    const character_update = std.json.parseFromSliceLeaky(
        zttrpg.UpdateCharacter,
        gpa,
        body,
        .{},
    ) catch {
        try writer.writer.print("Invalid JSON body.\n", .{});
        try request.respond(writer.written(), .{ .status = .bad_request, .keep_alive = false });
        return;
    };

    character_update.validate() catch {
        try writer.writer.print("Invalid character update\n", .{});
        try request.respond(writer.written(), .{ .status = .bad_request, .keep_alive = false });
        return;
    };

    db.updateCharacter(gpa, id, character_update) catch |err| {
        switch (err) {
            error.CharacterNotFound => {
                try writer.writer.print("Character with ID {d} not found.\n", .{id});
                try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
            },
            else => {
                try writer.writer.print("Failed to update character with ID {d}: {}\n", .{ id, err });
                try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
            },
        }
        return;
    };

    try writer.writer.print("Updated character with ID {d}.\n", .{id});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false });
}

fn deleteCharacter(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    id: u32,
) !void {
    db.deleteCharacter(gpa, id) catch |err| {
        switch (err) {
            error.CharacterNotFound => {
                try writer.writer.print("Character with ID {d} not found.\n", .{id});
                try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
            },
            else => {
                try writer.writer.print("Failed to delete character with ID {d}.\n", .{id});
                try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
            },
        }
        return;
    };

    try writer.writer.print("Deleted character with ID {d}.\n", .{id});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false });
}

fn respondCharacters(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    const characters = try db.readCharactersAlloc(gpa);
    try std.json.Stringify.value(characters, .{}, &writer.writer);
    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(writer.written(), .{ .keep_alive = false, .extra_headers = &.{extra_header} });
}

fn respondCharacter(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    id: u32,
) !void {
    const character = db.readCharacter(gpa, id) catch {
        try writer.writer.print("Failed to read character with ID {d}.\n", .{id});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    if (character == null) {
        try writer.writer.print("Character with ID {d} not found.\n", .{id});
        try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
        return;
    }

    try std.json.Stringify.value(character.?, .{}, &writer.writer);
    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(writer.written(), .{ .keep_alive = false, .extra_headers = &.{extra_header} });
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

    character.validate() catch |err| {
        try writer.writer.print("Invalid character: {}\n", .{err});
        try request.respond(writer.written(), .{ .status = .bad_request, .keep_alive = false });
        return;
    };

    const character_id = db.insertCharacter(gpa, character) catch {
        try writer.writer.print("Failed to insert character.\n", .{});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    std.debug.print("Inserted character: {s} (level {d}) with ID {d}\n", .{ character.name, character.level, character_id });

    const new_character = try zttrpg.Character.init(gpa, character_id, character.name, character.level);
    try std.json.Stringify.value(new_character, .{}, &writer.writer);

    try request.respond(writer.written(), .{ .status = .created, .keep_alive = false });
}
