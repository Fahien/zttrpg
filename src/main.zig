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
    var server = try ip_address.listen(init.io, .{ .mode = .stream, .reuse_address = true });
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
    skill_kinds,
    skills,
    icons,
    attributes,
};

const ResourceItem = struct {
    resource: Resource,
    id: u32,
};

/// SubResource is a subset of Resource that can be used to identify sub-resources of a resource.
/// For example, a character can have attributes and skills.
const SubResource = enum {
    attributes,
    skills,
};

/// SubCollection represents a sub-resource collection of a resource item.
/// For example, a character can have a collection of attributes or skills.
const SubCollection = struct {
    resource: Resource,
    id: u32,
    subresource: SubResource,
};

const Route = union(enum) {
    root,
    collection: Resource,
    item: ResourceItem,
    sub_collection: SubCollection,
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

        // Item.
        const next_segment = sequence.next() orelse unreachable;
        const id = std.fmt.parseInt(u32, next_segment, 10) catch return Route.not_found;

        const maybe_next_after_id = sequence.peek();
        if (maybe_next_after_id == null) {
            return .{ .item = .{ .resource = resource, .id = id } };
        }

        // Sub-collection.
        const next_after_id = sequence.next() orelse unreachable;
        const subresource = std.meta.stringToEnum(SubResource, next_after_id) orelse return Route.not_found;

        // Values are written a whole sub-collection at a time, so a single one
        // has no URL of its own: /characters/3/skills/7 stays a 404.
        const maybe_next_after_sub = sequence.peek();
        if (maybe_next_after_sub != null) {
            return Route.not_found;
        }

        return .{ .sub_collection = .{ .resource = resource, .id = id, .subresource = subresource } };
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
        .sub_collection => |sub| try handleSubCollection(sub, gpa, &writer, db, &request),
        .static => |path| try handleStatic(gpa, init.io, &writer, &request, path),
        .not_found => try handleNotFound(&writer, &request),
    }
}

fn handleNotFound(writer: *Io.Writer.Allocating, request: *std.http.Server.Request) !void {
    try writer.writer.print("404 Not Found\n", .{});
    try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
}

const ErrorResponse = struct {
    status: std.http.Status,
    message: []const u8,
};

/// The single place an error becomes an HTTP status. Deciding this per handler
/// is how a duplicate character name -- a client mistake Postgres reports as
/// SQLSTATE 23505 -- ended up answering 500 instead of 409.
///
/// The method matters for one code: Postgres raises a foreign key violation
/// both when a body references a row that does not exist (the client sent bad
/// input) and when a DELETE would orphan rows that do (the client asked for
/// something the current state forbids).
fn responseForError(err: anyerror, method: std.http.Method) ErrorResponse {
    return switch (err) {
        error.ItemNotFound => .{ .status = .not_found, .message = "Not found." },

        error.InvalidJsonBody => .{ .status = .bad_request, .message = "Invalid JSON body." },

        error.UniqueViolation => .{
            .status = .conflict,
            .message = "A record with that value already exists.",
        },

        error.ForeignKeyViolation => switch (method) {
            .DELETE => .{
                .status = .conflict,
                .message = "Other records still reference this one.",
            },
            else => .{
                .status = .bad_request,
                .message = "The request references a record that does not exist.",
            },
        },

        // Reachable only when the model's validation and the CHECK constraints
        // in db/ have drifted apart: the request passed the first and not the
        // second. Still the client's input, so still a 400.
        error.NotNullViolation, error.CheckViolation => .{
            .status = .bad_request,
            .message = "The request violates a constraint on this resource.",
        },

        // Domain errors raised by the model layer's validate(). The model says
        // what is wrong; choosing the status is this layer's job.
        error.EmptyName,
        error.EmptyShort,
        error.EmptyDescription,
        error.LevelOutOfRange,
        error.ValueOutOfRange,
        error.DuplicateEntry,
        => .{ .status = .bad_request, .message = "The request body is not valid." },

        else => .{ .status = .internal_server_error, .message = "Internal server error." },
    };
}

/// Answers a failed request. The client gets a stable message and the real
/// error goes to the log, so internal names never travel over the wire.
fn respondError(
    writer: *Io.Writer.Allocating,
    request: *std.http.Server.Request,
    err: anyerror,
) !void {
    const response = responseForError(err, request.head.method);

    // Not request.head.target: reading a body calls Head.invalidateStrings,
    // which sets target to undefined, and printing it then crashes the server.
    // The target is already on the "Received request" line above this one.
    // `method` survives, being an enum rather than a slice into the buffer.
    std.debug.print("{} -> {d}: {}\n", .{
        request.head.method,
        @intFromEnum(response.status),
        err,
    });

    try writer.writer.print("{s}\n", .{response.message});
    try request.respond(writer.written(), .{ .status = response.status, .keep_alive = false });
}

fn handleMethodNotAllowed(writer: *Io.Writer.Allocating, request: *std.http.Server.Request, method: std.http.Method) !void {
    try writer.writer.print("Method {} not allowed for this path.\n", .{method});
    try request.respond(writer.written(), .{ .status = .method_not_allowed, .keep_alive = false });
}

fn handleRoot(gpa: Allocator, io: Io, writer: *Io.Writer.Allocating, request: *std.http.Server.Request) !void {
    try servePage(gpa, io, writer, request, "index.html", "ZTTRPG");
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
    const title = try std.fmt.allocPrint(gpa, "ZTTRPG - {s}", .{@tagName(resource)});
    title[0] = std.ascii.toUpper(title[0]);
    try servePage(gpa, io, writer, request, sub_path, title);
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
    } else if (std.mem.endsWith(u8, sub_path, ".svg")) {
        content_type = "image/svg+xml";
    }

    const content_type_header = std.http.Header{
        .name = "Content-Type",
        .value = content_type,
    };
    try writer.writer.print("{s}", .{file_content});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false, .extra_headers = &.{content_type_header} });
}

fn servePage(
    gpa: Allocator,
    io: Io,
    writer: *Io.Writer.Allocating,
    request: *std.http.Server.Request,
    sub_path: []const u8,
    title: []const u8,
) !void {
    const web_dir = try Io.Dir.cwd().openDir(io, "src/web", .{});
    defer web_dir.close(io);

    var file_content = web_dir.readFileAlloc(io, sub_path, gpa, .limited(4096 * 16)) catch |err| {
        std.debug.print("Failed to read file: {s}, error: {}\n", .{ sub_path, err });
        try writer.writer.print("404 Not Found\n", .{});
        try request.respond(writer.written(), .{ .status = .not_found, .keep_alive = false });
        return;
    };

    const head_partial = web_dir.readFileAlloc(io, "partials/head.html", gpa, .limited(4096)) catch |err| {
        std.debug.print("Failed to assemble page, error: {}\n", .{err});
        try writer.writer.print("500 Internal Server Error\n", .{});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    const header_partial = web_dir.readFileAlloc(io, "partials/header.html", gpa, .limited(4096)) catch |err| {
        std.debug.print("Failed to assemble page, error: {}\n", .{err});
        try writer.writer.print("500 Internal Server Error\n", .{});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    const footer_partial = web_dir.readFileAlloc(io, "partials/footer.html", gpa, .limited(4096)) catch |err| {
        std.debug.print("Failed to assemble page, error: {}\n", .{err});
        try writer.writer.print("500 Internal Server Error\n", .{});
        try request.respond(writer.written(), .{ .status = .internal_server_error, .keep_alive = false });
        return;
    };

    file_content = try autoReplace(gpa, file_content, "{{head}}", head_partial);
    file_content = try autoReplace(gpa, file_content, "{{header}}", header_partial);
    file_content = try autoReplace(gpa, file_content, "{{footer}}", footer_partial);
    file_content = try autoReplace(gpa, file_content, "{{title}}", title);

    const content_type_header = std.http.Header{
        .name = "Content-Type",
        .value = "text/html",
    };
    try writer.writer.print("{s}", .{file_content});
    try request.respond(writer.written(), .{ .status = .ok, .keep_alive = false, .extra_headers = &.{content_type_header} });
}

fn autoReplace(gpa: Allocator, source: []const u8, placeholder: []const u8, replacement: []const u8) ![]u8 {
    const new_size = std.mem.replacementSize(u8, source, placeholder, replacement);
    const new_buffer = try gpa.alloc(u8, new_size);
    _ = std.mem.replace(u8, source, placeholder, replacement, new_buffer);
    return new_buffer;
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
                    .characters => try respondItems(gpa, writer, db, request, zttrpg.Character),
                    .kins => try respondItems(gpa, writer, db, request, zttrpg.Kin),
                    .skill_kinds => try respondItems(gpa, writer, db, request, zttrpg.SkillKind),
                    .skills => try respondItems(gpa, writer, db, request, zttrpg.Skill),
                    .icons => try respondItems(gpa, writer, db, request, zttrpg.Icon),
                    .attributes => try respondItems(gpa, writer, db, request, zttrpg.Attribute),
                }
            } else {
                try serveResource(gpa, io, writer, request, resource, Page.index);
            }
        },
        .POST => {
            switch (resource) {
                .characters => try insertItem(gpa, writer, db, request, zttrpg.Character),
                .kins => try insertItem(gpa, writer, db, request, zttrpg.Kin),
                .skill_kinds => try insertItem(gpa, writer, db, request, zttrpg.SkillKind),
                .skills => try insertItem(gpa, writer, db, request, zttrpg.Skill),
                .icons => try insertItem(gpa, writer, db, request, zttrpg.Icon),
                .attributes => try insertItem(gpa, writer, db, request, zttrpg.Attribute),
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
                    .skill_kinds => try respondItem(gpa, writer, db, request, zttrpg.SkillKind, item.id),
                    .skills => try respondItem(gpa, writer, db, request, zttrpg.Skill, item.id),
                    .icons => try respondItem(gpa, writer, db, request, zttrpg.Icon, item.id),
                    .attributes => try respondItem(gpa, writer, db, request, zttrpg.Attribute, item.id),
                }
            } else {
                try serveResource(gpa, io, writer, request, item.resource, Page.item);
            }
        },
        .DELETE => switch (item.resource) {
            .characters => try deleteItem(gpa, writer, db, request, zttrpg.Character, item.id),
            .kins => try deleteItem(gpa, writer, db, request, zttrpg.Kin, item.id),
            .skill_kinds => try deleteItem(gpa, writer, db, request, zttrpg.SkillKind, item.id),
            .skills => try deleteItem(gpa, writer, db, request, zttrpg.Skill, item.id),
            .icons => try deleteItem(gpa, writer, db, request, zttrpg.Icon, item.id),
            .attributes => try deleteItem(gpa, writer, db, request, zttrpg.Attribute, item.id),
        },
        .PUT => switch (item.resource) {
            .characters => try updateItem(gpa, writer, db, request, zttrpg.Character, item.id),
            .kins => try updateItem(gpa, writer, db, request, zttrpg.Kin, item.id),
            .skill_kinds => try updateItem(gpa, writer, db, request, zttrpg.SkillKind, item.id),
            .skills => try updateItem(gpa, writer, db, request, zttrpg.Skill, item.id),
            .icons => try updateItem(gpa, writer, db, request, zttrpg.Icon, item.id),
            .attributes => try updateItem(gpa, writer, db, request, zttrpg.Attribute, item.id),
        },
        else => |method| try handleMethodNotAllowed(writer, request, method),
    }
}

fn updateItem(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    comptime T: type,
    id: u32,
) !void {
    const scratch_buffer = try gpa.alloc(u8, 4096);
    const reader = try request.readerExpectContinue(scratch_buffer);
    const body = try reader.allocRemaining(gpa, .limited(4096));

    const update = std.json.parseFromSliceLeaky(
        T.Update,
        gpa,
        body,
        .{},
    ) catch |err| {
        // std.json's error set is wide and none of it changes the answer, so
        // it collapses into one error the mapping knows.
        std.debug.print("Malformed " ++ @typeName(T) ++ " body: {}\n", .{err});
        return respondError(writer, request, error.InvalidJsonBody);
    };

    update.validate() catch |err| return respondError(writer, request, err);

    db.updateItem(gpa, T, id, update) catch |err| return respondError(writer, request, err);

    try writer.writer.print("Updated item with ID {d}.\n", .{id});
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
    db.deleteItem(gpa, T, id) catch |err| return respondError(writer, request, err);

    try writer.writer.print("Deleted item with ID {d}.\n", .{id});
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

fn respondItems(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    comptime T: type,
) !void {
    const items = db.readAllAlloc(gpa, T, null, 0) catch |err| return respondError(writer, request, err);
    try std.json.Stringify.value(items, .{}, &writer.writer);
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
    const item = db.readItem(gpa, T, id) catch |err| return respondError(writer, request, err);

    // readItem reports a missing row as null rather than an error; the answer
    // is the same 404 a delete or update of that row would give.
    if (item == null) {
        return respondError(writer, request, error.ItemNotFound);
    }

    try std.json.Stringify.value(item.?, .{}, &writer.writer);
    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(writer.written(), .{ .keep_alive = false, .extra_headers = &.{extra_header} });
}

fn insertItem(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    comptime T: type,
) !void {
    const scratch_buffer = try gpa.alloc(u8, 4096);
    const reader = try request.readerExpectContinue(scratch_buffer);
    const body = try reader.allocRemaining(gpa, .limited(4096));

    const item = std.json.parseFromSliceLeaky(
        T.Create,
        gpa,
        body,
        .{},
    ) catch |err| {
        std.debug.print("Malformed " ++ @typeName(T) ++ " body: {}\n", .{err});
        return respondError(writer, request, error.InvalidJsonBody);
    };

    item.validate() catch |err| return respondError(writer, request, err);

    // A name that is already taken arrives here as UniqueViolation, and a kin
    // that does not exist as ForeignKeyViolation: both are the client's doing.
    const item_id = db.insertItem(gpa, T, item) catch |err| return respondError(writer, request, err);

    std.debug.print("Inserted " ++ @typeName(T) ++ " with ID {d}\n", .{item_id});

    try respondItem(gpa, writer, db, request, T, item_id);
}

fn handleSubCollection(
    sub: SubCollection,
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method == .GET and wantsJson(request)) {
        switch (sub.resource) {
            .characters => switch (sub.subresource) {
                .attributes => try respondSubCollection(gpa, writer, db, request, zttrpg.Character, zttrpg.CharacterAttribute, sub.id),
                .skills => try respondSubCollection(gpa, writer, db, request, zttrpg.Character, zttrpg.CharacterSkill, sub.id),
            },
            else => {
                try handleNotFound(writer, request);
            },
        }
    } else {
        try handleMethodNotAllowed(writer, request, request.head.method);
    }
}

fn respondSubCollection(
    gpa: Allocator,
    writer: *Io.Writer.Allocating,
    db: *const zttrpg.Database,
    request: *std.http.Server.Request,
    comptime ParentResource: type,
    comptime ChildSubResource: type,
    parent_id: u32,
) !void {
    const children = db.readSubResource(gpa, ParentResource, ChildSubResource, parent_id) catch |err|
        return respondError(writer, request, err);

    try std.json.Stringify.value(children, .{}, &writer.writer);
    const extra_header = std.http.Header{
        .name = "Content-Type",
        .value = "application/json",
    };
    try request.respond(writer.written(), .{ .keep_alive = false, .extra_headers = &.{extra_header} });
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

test "parseRoute: character sub-collections" {
    const skills = Route{ .sub_collection = .{ .resource = .characters, .id = 3, .subresource = .skills } };

    try std.testing.expectEqual(skills, Route.parseRoute("/characters/3/skills"));
    // Same trailing-slash and query-string policy as every other route.
    try std.testing.expectEqual(skills, Route.parseRoute("/characters/3/skills/"));
    try std.testing.expectEqual(skills, Route.parseRoute("/characters/3/skills?sort=name"));

    try std.testing.expectEqual(
        Route{ .sub_collection = .{ .resource = .characters, .id = 3, .subresource = .attributes } },
        Route.parseRoute("/characters/3/attributes"),
    );
}

test "parseRoute: nothing routes below a sub-collection" {
    // Values are written a whole sub-collection at a time, so a single value
    // has no URL of its own. Dropping this guard would quietly route
    // /characters/3/skills/7 to the whole collection instead of a 404.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/3/skills/7"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/3/skills/7/extra"));
}

test "parseRoute: only SubResource names route below an id" {
    // 'kins' is a Resource but not a SubResource, so the separate enum is what
    // keeps /characters/3/kins from parsing.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/3/kins"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/3/bogus"));
}

test "parseRoute: a sub-collection on the wrong resource still parses" {
    // SubResource says which names *are* sub-collections, not which resources
    // *have* them, so nothing here rejects /kins/3/skills. Pinning the current
    // behaviour makes the leftover check a handler's job, not an oversight.
    try std.testing.expectEqual(
        Route{ .sub_collection = .{ .resource = .kins, .id = 3, .subresource = .skills } },
        Route.parseRoute("/kins/3/skills"),
    );
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

test "every resource ships its index and item pages" {
    // Pages are read from disk at request time, so a missing file would only
    // surface as a runtime 404. Embedding each expected page here makes
    // "resource without its HTML" fail the build instead.
    inline for (@typeInfo(Resource).@"enum".fields) |resource| {
        inline for (@typeInfo(Page).@"enum".fields) |page| {
            _ = @embedFile("web/" ++ resource.name ++ "/" ++ page.name ++ ".html");
        }
    }
}

test "every resource routes as a collection and as an item" {
    // parseRoute resolves the first segment with stringToEnum over Resource, so
    // a new resource becomes routable the moment it joins the enum. Looping over
    // the enum instead of naming each resource keeps this from falling behind.
    inline for (@typeInfo(Resource).@"enum".fields) |field| {
        const resource: Resource = @enumFromInt(field.value);

        try std.testing.expectEqual(
            Route{ .collection = resource },
            Route.parseRoute("/" ++ field.name),
        );
        try std.testing.expectEqual(
            Route{ .item = .{ .resource = resource, .id = 7 } },
            Route.parseRoute("/" ++ field.name ++ "/7"),
        );
    }
}

test "every sub-resource routes under a character" {
    // As with Resource above: looping the enum means a new sub-resource is
    // covered the moment it joins SubResource, instead of being forgotten here.
    inline for (@typeInfo(SubResource).@"enum".fields) |field| {
        const subresource: SubResource = @enumFromInt(field.value);

        try std.testing.expectEqual(
            Route{ .sub_collection = .{ .resource = .characters, .id = 7, .subresource = subresource } },
            Route.parseRoute("/characters/7/" ++ field.name),
        );
    }
}

test "every page wires up the ids its shared script looks up" {
    // roster.js and instance.js are shared by every resource and find their
    // elements by id. A page that names an element after its own resource
    // (#kin-details) still renders, so the break only shows up as a dead error
    // path in the browser: pin the contract at build time instead.
    inline for (@typeInfo(Resource).@"enum".fields) |resource| {
        const index_page = @embedFile("web/" ++ resource.name ++ "/index.html");
        for ([_][]const u8{ "resource-name", "roster" }) |id| {
            expectContainsId(index_page, id) catch |err| {
                std.debug.print("index page for {s} is missing {s}\n", .{ resource.name, id });
                return err;
            };
        }

        const item_page = @embedFile("web/" ++ resource.name ++ "/item.html");
        for ([_][]const u8{"instance-details"}) |id| {
            try expectContainsId(item_page, id);
        }
    }
}

fn expectContainsId(page: []const u8, id: []const u8) !void {
    var buffer: [64]u8 = undefined;
    const attribute = try std.fmt.bufPrint(&buffer, "id=\"{s}\"", .{id});
    if (std.mem.find(u8, page, attribute) == null) {
        std.debug.print("page is missing {s}\n", .{attribute});
        return error.MissingElementId;
    }
}

test "parseRoute: rejections" {
    // Unknown top-level segment.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/nope"));
    // Ids must be numeric, in range for u32, and positive.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/alice"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/-1"));
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/99999999999"));
    // Only SubResource names route below a character id.
    try std.testing.expectEqual(Route.not_found, Route.parseRoute("/characters/3/junk"));
}
