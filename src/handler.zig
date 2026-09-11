// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! What each route does. Every handler takes the request Context and answers
//! through it; none of them builds a response by hand.

const std = @import("std");
const zttrpg = @import("zttrpg");

const context = @import("context.zig");
const page = @import("page.zig");
const route = @import("route.zig");

const Context = context.Context;
const Page = page.Page;
const Resource = route.Resource;
const ResourceItem = route.ResourceItem;
const Route = route.Route;
const SubCollection = route.SubCollection;
const SubResource = route.SubResource;

/// A single record's body. Generous for the four fields any model has.
const max_item_body = 4096;

/// A whole sub-collection at once. A full sheet of skills is roughly 2 KB of
/// compact JSON; this leaves room for a body a human formatted without letting
/// one request allocate without bound.
const max_sub_collection_body = 4096 * 16;

/// Sends a parsed route to the handler that answers it.
pub fn dispatch(ctx: *Context, parsed: Route) !void {
    switch (parsed) {
        .root => try page.serveIndex(ctx),
        .collection => |resource| try handleCollection(ctx, resource),
        .item => |item| try handleItem(ctx, item),
        .item_edit => |item| try handleItemEdit(ctx, item),
        .sub_collection => |sub| try handleSubCollection(ctx, sub),
        .static => |path| try page.serveStatic(ctx, path),
        .not_found => try ctx.notFound(),
    }
}

fn handleCollection(ctx: *Context, resource: Resource) !void {
    // `inline else` generates one arm per resource with the tag comptime-known,
    // which is what lets a single switch serve every method: without it each
    // method needs its own copy of the resource list.
    switch (resource) {
        inline else => |r| {
            const definition = comptime r.definition();
            const Model = definition.Model;

            switch (ctx.method()) {
                .GET => if (!definition.html or ctx.wantsJson())
                    try respondItems(ctx, Model)
                else
                    try page.serveResource(ctx, r, Page.index),

                .POST => if (definition.create)
                    try insertItem(ctx, Model)
                else
                    try ctx.methodNotAllowed(),

                else => try ctx.methodNotAllowed(),
            }
        },
    }
}

fn handleItem(ctx: *Context, item: ResourceItem) !void {
    switch (item.resource) {
        inline else => |r| {
            const definition = comptime r.definition();
            const Model = definition.Model;

            // A parsed item URL need not be supported by the resource.
            if (!definition.item) return ctx.notFound();

            switch (ctx.method()) {
                .GET => if (!definition.html or ctx.wantsJson())
                    try respondItem(ctx, Model, item.id)
                else
                    try page.serveResource(ctx, item.resource, Page.item),

                .DELETE => if (definition.delete)
                    try deleteItem(ctx, Model, item.id)
                else
                    try ctx.methodNotAllowed(),

                .PUT => if (definition.update)
                    try updateItem(ctx, Model, item.id)
                else
                    try ctx.methodNotAllowed(),

                else => try ctx.methodNotAllowed(),
            }
        },
    }
}

fn handleItemEdit(ctx: *Context, item: ResourceItem) !void {
    switch (item.resource) {
        inline else => |r| {
            const definition = comptime r.definition();

            if (!definition.item or !definition.html or !definition.edit) return ctx.notFound();
            if (ctx.method() != .GET or ctx.wantsJson()) return ctx.methodNotAllowed();

            try page.serveResource(ctx, item.resource, Page.edit);
        },
    }
}

/// The shape a whole collection is served as. A model that declares a `Summary`
/// is listed in that shape; every other model lists as itself.
///
/// Choosing between them belongs here rather than in the model or the query
/// layer: it is a statement about what one endpoint returns, not about what the
/// record is. The query layer reads whichever type it is handed.
fn SummaryOf(comptime T: type) type {
    return if (@hasDecl(T, "Summary")) T.Summary else T;
}

fn respondItems(ctx: *Context, comptime T: type) !void {
    // A roster shows a few columns per row, so listing every character with its
    // whole sheet costs one query per value nobody displays.
    const items = items: {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        break :items db.readAllAlloc(ctx.gpa, SummaryOf(T));
    } catch |err| return ctx.respondError(err);

    try ctx.respondJson(items);
}

fn respondItem(ctx: *Context, comptime T: type, id: u32) !void {
    const item = item: {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        break :item db.readItem(ctx.gpa, T, id);
    } catch |err| return ctx.respondError(err);

    // readItem reports a missing row as null rather than an error; the answer
    // is the same 404 a delete or update of that row would give.
    if (item == null) return ctx.respondError(error.ItemNotFound);

    try ctx.respondJson(item.?);
}

/// Parses a request body, answering a 400 rather than propagating.
///
/// std.json's error set is wide and none of it changes the answer, so it
/// collapses into the one error the status mapping knows.
fn parseBody(ctx: *Context, comptime T: type, limit: usize) !?T {
    const body = ctx.readBody(limit) catch |err| {
        try ctx.respondError(err);
        return null;
    };

    return std.json.parseFromSliceLeaky(T, ctx.gpa, body, .{}) catch |err| {
        std.debug.print("Malformed " ++ @typeName(T) ++ " body: {}\n", .{err});
        try ctx.respondError(error.InvalidJsonBody);
        return null;
    };
}

fn insertItem(ctx: *Context, comptime T: type) !void {
    const item = try parseBody(ctx, T.Create, max_item_body) orelse return;

    item.validate() catch |err| return ctx.respondError(err);

    // A name that is already taken arrives here as UniqueViolation, and a kin
    // that does not exist as ForeignKeyViolation: both are the client's doing.
    const item_id = item_id: {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        break :item_id db.insertItem(ctx.gpa, T, item);
    } catch |err| return ctx.respondError(err);

    std.debug.print("Inserted " ++ @typeName(T) ++ " with ID {d}\n", .{item_id});

    try respondItem(ctx, T, item_id);
}

fn updateItem(ctx: *Context, comptime T: type, id: u32) !void {
    const update = try parseBody(ctx, T.Update, max_item_body) orelse return;

    update.validate() catch |err| return ctx.respondError(err);

    {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        db.updateItem(ctx.gpa, T, id, update) catch |err| return ctx.respondError(err);
    }

    try ctx.respondText(.ok, "Updated item with ID {d}.\n", .{id});
}

fn deleteItem(ctx: *Context, comptime T: type, id: u32) !void {
    {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        db.deleteItem(ctx.gpa, T, id) catch |err| return ctx.respondError(err);
    }

    try ctx.respondText(.ok, "Deleted item with ID {d}.\n", .{id});
}

fn handleSubCollection(ctx: *Context, sub: SubCollection) !void {
    switch (sub.resource) {
        inline else => |resource| {
            const resource_definition = comptime resource.definition();
            switch (sub.subresource) {
                inline else => |subresource| {
                    if (!comptime resource_definition.hasSubresource(subresource)) return ctx.notFound();

                    const definition = comptime subresource.definition();
                    const Parent = definition.Parent;
                    const Model = definition.Model;
                    switch (comptime definition.kind) {
                        .collection => switch (ctx.method()) {
                            // No HTML page lives at this URL: a browser asking for one gets
                            // a 404 rather than being told GET is not allowed.
                            .GET => if (ctx.wantsJson())
                                try respondSubCollection(ctx, Parent, Model, sub.id)
                            else
                                try ctx.notFound(),
                            .PUT => try updateSubCollection(ctx, Parent, Model, sub.id),
                            else => try ctx.methodNotAllowed(),
                        },
                        .action => switch (ctx.method()) {
                            .PUT => try applySubAction(ctx, Parent, Model, sub.id),
                            else => try ctx.methodNotAllowed(),
                        },
                    }
                },
            }
        },
    }
}

fn respondSubCollection(
    ctx: *Context,
    comptime Parent: type,
    comptime Child: type,
    parent_id: u32,
) !void {
    const children = children: {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        break :children db.readSubResource(ctx.gpa, Parent, Child, parent_id);
    } catch |err| return ctx.respondError(err);

    try ctx.respondJson(children);
}

/// Writes a whole sub-collection at once: the body is the complete list of
/// values for this character, which is why a single value has no URL of its own.
fn updateSubCollection(
    ctx: *Context,
    comptime Parent: type,
    comptime Child: type,
    parent_id: u32,
) !void {
    const bodies = try parseBody(ctx, []const Child.Body, max_sub_collection_body) orelse return;

    // Checks every value against the CHECK constraint, and rejects a repeated
    // key -- the one rule Postgres cannot catch, because two UPDATEs against
    // the same row both succeed and the last one silently wins.
    Child.Body.validateAll(bodies) catch |err| return ctx.respondError(err);

    // One transaction for the whole sheet: a body that names a value this
    // character does not have leaves the other values unchanged.
    {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        db.updateSubResource(ctx.gpa, Parent, Child, parent_id, bodies) catch |err|
            return ctx.respondError(err);
    }

    // The sheet changed, and so did what follows from it: the pool the
    // database debited and the movement derived from the new values. Answer
    // with the whole character, as a create does, so the page re-renders from
    // the same shape it loaded rather than bookkeeping the consequences itself.
    try respondItem(ctx, Parent, parent_id);
}

fn applySubAction(
    ctx: *Context,
    comptime Parent: type,
    comptime Action: type,
    parent_id: u32,
) !void {
    const body = try parseBody(ctx, Action.Body, max_sub_collection_body) orelse return;
    Action.Body.validate(&body) catch |err| return ctx.respondError(err);

    {
        const db = try ctx.db.lock();
        defer ctx.db.unlock();
        db.applySubAction(ctx.gpa, Parent, Action, parent_id, body) catch |err|
            return ctx.respondError(err);
    }

    try respondItem(ctx, Parent, parent_id);
}

test "resource models satisfy their declared capabilities" {
    inline for (@typeInfo(Resource).@"enum".fields) |field| {
        const resource: Resource = @enumFromInt(field.value);
        const definition = comptime resource.definition();
        const Model = definition.Model;

        try std.testing.expect(@hasDecl(Model, "table_name"));
        if (definition.item or definition.create) {
            const Row = if (@hasDecl(Model, "Row")) Model.Row else Model;
            try std.testing.expect(@hasField(Row, "id"));
        }
        if (definition.create) {
            try std.testing.expect(@hasDecl(Model.Create, "validate"));
            try std.testing.expect(!@hasField(Model.Create, "id"));
        }
        if (definition.update) {
            try std.testing.expect(@hasDecl(Model.Update, "validate"));
        }
        // Current write handlers operate on, or return, an item addressed by id.
        try std.testing.expect(definition.item or !(definition.create or definition.update or definition.delete));
    }
}

test "unsupported resource operations are rejected before accessing the database" {
    inline for (@typeInfo(Resource).@"enum".fields) |field| {
        const resource: Resource = @enumFromInt(field.value);
        const definition = comptime resource.definition();
        const path = "/" ++ field.name;

        if (!definition.create) try expectRejectedRequest("POST", path, "405 Method Not Allowed");
        inline for (.{ "GET", "PUT", "DELETE" }) |method| {
            if (!definition.item) try expectRejectedRequest(method, path ++ "/7", "404 Not Found");
        }
        if (definition.item and !definition.update) try expectRejectedRequest("PUT", path ++ "/7", "405 Method Not Allowed");
        if (definition.item and !definition.delete) try expectRejectedRequest("DELETE", path ++ "/7", "405 Method Not Allowed");
    }
}

fn expectRejectedRequest(comptime method: []const u8, comptime path: []const u8, comptime status: []const u8) !void {
    var input = std.Io.Reader.fixed(method ++ " " ++ path ++ " HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var server = std.http.Server.init(&input, &output.writer);
    var request = try server.receiveHead();

    // Rejected operations must never use the database or allocate a body.
    var ctx = Context.init(std.testing.allocator, std.testing.io, undefined, &request);
    defer ctx.writer.deinit();
    try dispatch(&ctx, Route.parseRoute(request.head.target));
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "HTTP/1.1 " ++ status ++ "\r\n"));
}

test "every registered sub-resource declares the operation its handler needs" {
    // The dispatch path is driven by SubResource.definition and Resource
    // metadata. Pinning the required declarations here makes a newly added
    // nested operation fail at build time rather than on its first request.
    inline for (@typeInfo(SubResource).@"enum".fields) |field| {
        const subresource: SubResource = @enumFromInt(field.value);
        const definition = comptime subresource.definition();
        const Model = definition.Model;

        try std.testing.expect(@hasDecl(Model, "Body"));
        try std.testing.expect(!@hasField(Model.Body, "character"));
        switch (comptime definition.kind) {
            .collection => {
                try std.testing.expect(@hasDecl(Model, "table_name"));
                try std.testing.expect(@hasDecl(Model.Body, "validateAll"));
            },
            .action => {
                try std.testing.expect(@hasDecl(Model, "apply"));
                try std.testing.expect(@hasDecl(Model.Body, "validate"));
            },
        }
    }
}
