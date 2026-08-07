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

const Resource = enum {
    characters,
    kins,
};

const ResourceItem = struct {
    resource: Resource,
    id: u32,
};

const Route = union(enum) {
    root,
    collection: Resource,
    item: ResourceItem,
    static: []const u8,
    not_found,

    fn parseRoute(target: []const u8) Route {
        const trimmed_target = std.mem.trim(u8, target, "/");
        var path_and_query = std.mem.splitScalar(u8, trimmed_target, '?');
        const path = path_and_query.next() orelse return Route.not_found;

        var sequence = std.mem.splitScalar(u8, path, '/');
        const maybe_first_segment = sequence.peek();

        // Root case.
        if (maybe_first_segment == null or std.mem.eql(u8, maybe_first_segment.?, "")) {
            return Route.root;
        }

        const first_segment = sequence.next() orelse unreachable;

        // Static paths.
        if (std.mem.eql(u8, first_segment, "static")) {
            const maybe_next_segment = sequence.peek();
            if (maybe_next_segment == null) {
                return Route.not_found;
            }

            const dots_position = std.mem.find(u8, path, "..");
            if (dots_position != null) {
                return Route.not_found;
            }

            return .{ .static = path };
        }

        // Resources.
        const resource = std.meta.stringToEnum(Resource, first_segment) orelse return Route.not_found;

        const maybe_next_segment = sequence.peek();
        if (maybe_next_segment == null) {
            return .{ .collection = resource };
        }

        const next_segment = sequence.next() orelse unreachable;
        const id = std.fmt.parseInt(u32, next_segment, 10) catch return Route.not_found;

        const maybe_next_after_id = sequence.peek();
        if (maybe_next_after_id != null) {
            return Route.not_found;
        }

        return .{ .item = .{ .resource = resource, .id = id } };
    }
};

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

    const route = Route.parseRoute(request.head.target);

    switch (route) {
        .root => try handleRoot(gpa, init.io, &writer, &request),
        .collection => |resource| try handleCollection(resource, gpa, init.io, &writer, db, &request),
        .item => |item| try handleItem(item, gpa, init.io, &writer, db, &request),
        .static => |path| try handleStatic(gpa, init.io, &writer, &request, path),
        .not_found => try handleNotFound(&writer, &request),
    }
}

fn handleNotFound(writer: *Io.Writer.Allocating, request: *std.http.Server.Request) !void {
    try writer.writer.print("404 Not Found\n", .{});
    try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
}

fn handleMethodNotAllowed(writer: *Io.Writer.Allocating, request: *std.http.Server.Request, method: std.http.Method) !void {
    try writer.writer.print("Method {} not allowed for this path.\n", .{method});
    try request.respond(writer.written(), .{ .status = .method_not_allowed, .keep_alive = false });
}

fn handleRoot(gpa: Allocator, io: Io, writer: *Io.Writer.Allocating, request: *std.http.Server.Request) !void {
    try servePath(gpa, io, writer, request, "index.html");
}

fn handleStatic(
    gpa: Allocator,
    io: Io,
    writer: *Io.Writer.Allocating,
    request: *std.http.Server.Request,
    file_path: []const u8,
) !void {
    try servePath(gpa, io, writer, request, file_path);
}

fn serveResource(
    gpa: Allocator,
    io: Io,
    writer: *Io.Writer.Allocating,
    request: *std.http.Server.Request,
    resource: Resource,
    page: Page,
) !void {
    const sub_path = try std.fmt.allocPrint(gpa, "{s}/{s}.html", .{ @tagName(resource), @tagName(page) });
    try servePath(gpa, io, writer, request, sub_path);
}

fn servePath(
    gpa: Allocator,
    io: Io,
    writer: *Io.Writer.Allocating,
    request: *std.http.Server.Request,
    sub_path: []const u8,
) !void {
    const web_dir = try Io.Dir.cwd().openDir(io, "src/web", .{});
    defer web_dir.close(io);

    const file_content = web_dir.readFileAlloc(io, sub_path, gpa, .limited(4096 * 16)) catch |err| {
        std.debug.print("Failed to read file: {s}, error: {}\n", .{ sub_path, err });
        try writer.writer.print("404 Not Found\n", .{});
        try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
        return;
    };

    var content_type: []const u8 = "text/plain";
    if (std.mem.endsWith(u8, sub_path, ".css")) {
        content_type = "text/css";
    } else if (std.mem.endsWith(u8, sub_path, ".js")) {
        content_type = "application/javascript";
    } else if (std.mem.endsWith(u8, sub_path, ".html")) {
        content_type = "text/html";
    }

    const content_type_header = std.http.Header{
        .name = "Content-Type",
        .value = content_type,
    };
    try writer.writer.print("{s}", .{file_content});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false, .extra_headers = &.{content_type_header} });
}

fn handleCollection(
    resource: Resource,
    gpa: Allocator,
    io: Io,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    switch (request.head.method) {
        .GET => {
            if (wantsJson(request)) {
                switch (resource) {
                    .characters => try respondCharacters(gpa, writer, db, request),
                    .kins => try respondKins(gpa, writer, db, request),
                }
            } else {
                try serveResource(gpa, io, writer, request, resource, Page.index);
            }
        },
        .POST => {
            switch (resource) {
                .characters => try insertCharacter(gpa, writer, db, request),
                else => try handleNotFound(writer, request),
            }
        },
        else => |method| try handleMethodNotAllowed(writer, request, method),
    }
}

fn handleItem(
    item: ResourceItem,
    gpa: Allocator,
    io: Io,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    switch (request.head.method) {
        .GET => {
            if (wantsJson(request)) {
                switch (item.resource) {
                    .characters => try respondItem(gpa, writer, db, request, zttrpg.Character, item.id),
                    .kins => try respondItem(gpa, writer, db, request, zttrpg.Kin, item.id),
                }
            } else {
                try serveResource(gpa, io, writer, request, item.resource, Page.item);
            }
        },
        .DELETE => switch (item.resource) {
            .characters => try deleteItem(gpa, writer, db, request, zttrpg.Character, item.id),
            .kins => try deleteItem(gpa, writer, db, request, zttrpg.Kin, item.id),
        },
        .PUT => switch (item.resource) {
            .characters => try updateCharacter(gpa, writer, db, request, item.id),
            else => try handleNotFound(writer, request),
        },
        else => |method| try handleMethodNotAllowed(writer, request, method),
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

fn deleteItem(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    comptime T: type,
    id: u32,
) !void {
    db.deleteItem(gpa, T, id) catch |err| {
        switch (err) {
            error.ItemNotFound => {
                try writer.writer.print(@typeName(T) ++ " with ID {d} not found.\n", .{id});
                try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
            },
            else => {
                try writer.writer.print("Failed to delete " ++ @typeName(T) ++ " with ID {d}.\n", .{id});
                try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
            },
        }
        return;
    };

    try writer.writer.print("Deleted " ++ @typeName(T) ++ " with ID {d}.\n", .{id});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false });
}

fn wantsJson(request: *std.http.Server.Request) bool {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.mem.eql(u8, header.name, "Accept") and std.mem.eql(u8, header.value, "application/json")) {
            return true;
        }
    }
    return false;
}

const Page = enum { index, item };

fn respondCharacters(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    const characters = try db.readAllAlloc(gpa, zttrpg.Character);
    try std.json.Stringify.value(characters, .{}, &writer.writer);
    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(writer.written(), .{ .keep_alive = false, .extra_headers = &.{extra_header} });
}

fn respondKins(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    const kins = try db.readAllAlloc(gpa, zttrpg.Kin);
    try std.json.Stringify.value(kins, .{}, &writer.writer);
    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(writer.written(), .{ .keep_alive = false, .extra_headers = &.{extra_header} });
}

fn respondItem(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    comptime T: type,
    id: u32,
) !void {
    const character = db.readItem(gpa, T, id) catch {
        try writer.writer.print("Failed to read " ++ @typeName(T) ++ " with ID {d}.\n", .{id});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    if (character == null) {
        try writer.writer.print(@typeName(T) ++ " with ID {d} not found.\n", .{id});
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

    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(
        writer.written(),
        .{
            .status = .created,
            .keep_alive = false,
            .extra_headers = &.{extra_header},
        },
    );
}

test "parseRoute: root" {
    try std.testing.expectEqual(Route.root, Route.parseRoute("/"));
    try std.testing.expectEqual(Route.root, Route.parseRoute(""));
    // Trailing slashes are trimmed, so doubled slashes still mean root.
    try std.testing.expectEqual(Route.root, Route.parseRoute("//"));
}

test "parseRoute: characters collection" {
    try std.testing.expectEqual(Route{ .collection = .characters }, Route.parseRoute("/characters"));
    // Policy: a trailing slash is tolerated and means the same route.
    try std.testing.expectEqual(Route{ .collection = .characters }, Route.parseRoute("/characters/"));
    // Query strings are ignored for routing purposes.
    try std.testing.expectEqual(Route{ .collection = .characters }, Route.parseRoute("/characters?page=2"));
}

test "parseRoute: single character by id" {
    try std.testing.expectEqual(Route{ .item = .{ .resource = .characters, .id = 3 } }, Route.parseRoute("/characters/3"));
    try std.testing.expectEqual(Route{ .item = .{ .resource = .characters, .id = 3 } }, Route.parseRoute("/characters/3/"));
    try std.testing.expectEqual(Route{ .item = .{ .resource = .characters, .id = 3 } }, Route.parseRoute("/characters/3?verbose=1"));
    try std.testing.expectEqual(Route{ .item = .{ .resource = .characters, .id = 0 } }, Route.parseRoute("/characters/0"));
}

test "parseRoute: static assets" {
    // The payload is a slice, so expectEqual would compare pointers, not
    // content: check the tag first, then the payload text.
    const css = Route.parseRoute("/static/custom.css");
    try std.testing.expect(css == .static);
    try std.testing.expectEqualStrings("static/custom.css", css.static);

    const nested = Route.parseRoute("/static/js/character-form.js");
    try std.testing.expect(nested == .static);
    try std.testing.expectEqualStrings("static/js/character-form.js", nested.static);

    // Bare /static names no file.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/static"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/static/"));
}

test "parseRoute: static ignores query strings like every other route" {
    const versioned = Route.parseRoute("/static/custom.css?v=2");
    try std.testing.expect(versioned == .static);
    try std.testing.expectEqualStrings("static/custom.css", versioned.static);
}

test "parseRoute: static rejects path traversal" {
    // A '..' segment would let a request escape src/web and read arbitrary
    // files (e.g. GET /static/../../build.zig). Never route it.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/static/../secret.txt"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/static/../../build.zig"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/static/css/../../../etc/passwd"));
}

test "parseRoute: rejections" {
    // Unknown top-level segment.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/nope"));
    // Ids must be numeric, in range for u32, and positive.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/alice"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/-1"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/99999999999"));
    // Nothing is routed below a character id.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/3/junk"));
}
