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
        .sub_collection => |sub| try handleSubCollection(ctx, sub),
        .static => |path| try page.serveStatic(ctx, path),
        .not_found => try ctx.notFound(),
    }
}

/// The model each resource is stored and served as. This is the one place a URL
/// name and a Zig type are tied together: every handler reaches the type here,
/// so a new resource costs one line in `Resource` and one line below.
fn ModelOf(comptime resource: Resource) type {
    return switch (resource) {
        .characters => zttrpg.Character,
        .kins => zttrpg.Kin,
        .skill_kinds => zttrpg.SkillKind,
        .skills => zttrpg.Skill,
        .icons => zttrpg.Icon,
        .attributes => zttrpg.Attribute,
    };
}

fn handleCollection(ctx: *Context, resource: Resource) !void {
    // `inline else` generates one arm per resource with the tag comptime-known,
    // which is what lets a single switch serve every method: without it each
    // method needs its own copy of the resource list.
    switch (resource) {
        inline else => |r| {
            const Model = ModelOf(r);

            switch (ctx.method()) {
                .GET => if (ctx.wantsJson())
                    try respondItems(ctx, Model)
                else
                    try page.serveResource(ctx, r, Page.index),

                .POST => try insertItem(ctx, Model),

                else => try ctx.methodNotAllowed(),
            }
        },
    }
}

fn handleItem(ctx: *Context, item: ResourceItem) !void {
    switch (item.resource) {
        inline else => |r| {
            const Model = ModelOf(r);

            switch (ctx.method()) {
                .GET => if (ctx.wantsJson())
                    try respondItem(ctx, Model, item.id)
                else
                    try page.serveResource(ctx, r, Page.item),

                .DELETE => try deleteItem(ctx, Model, item.id),

                .PUT => try updateItem(ctx, Model, item.id),

                else => try ctx.methodNotAllowed(),
            }
        },
    }
}

fn respondItems(ctx: *Context, comptime T: type) !void {
    const items = ctx.db.readAllAlloc(ctx.gpa, T, null, 0) catch |err| return ctx.respondError(err);
    try ctx.respondJson(items);
}

fn respondItem(ctx: *Context, comptime T: type, id: u32) !void {
    const item = ctx.db.readItem(ctx.gpa, T, id) catch |err| return ctx.respondError(err);

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
    const item_id = ctx.db.insertItem(ctx.gpa, T, item) catch |err| return ctx.respondError(err);

    std.debug.print("Inserted " ++ @typeName(T) ++ " with ID {d}\n", .{item_id});

    try respondItem(ctx, T, item_id);
}

fn updateItem(ctx: *Context, comptime T: type, id: u32) !void {
    const update = try parseBody(ctx, T.Update, max_item_body) orelse return;

    update.validate() catch |err| return ctx.respondError(err);

    ctx.db.updateItem(ctx.gpa, T, id, update) catch |err| return ctx.respondError(err);

    try ctx.respondText(.ok, "Updated item with ID {d}.\n", .{id});
}

fn deleteItem(ctx: *Context, comptime T: type, id: u32) !void {
    ctx.db.deleteItem(ctx.gpa, T, id) catch |err| return ctx.respondError(err);

    try ctx.respondText(.ok, "Deleted item with ID {d}.\n", .{id});
}

/// The type a sub-collection's rows are read and written as. Naming the mapping
/// once is what keeps the read path and the write path from drifting apart.
fn ChildOf(comptime subresource: SubResource) type {
    return switch (subresource) {
        .attributes => zttrpg.CharacterAttribute,
        .skills => zttrpg.CharacterSkill,
    };
}

fn handleSubCollection(ctx: *Context, sub: SubCollection) !void {
    // SubResource says which names are sub-collections, not which resources
    // have them, so /kins/3/skills parses. This is where it stops.
    if (sub.resource != .characters) return ctx.notFound();

    // `inline else` makes the tag comptime-known inside the arm, so one switch
    // serves every method instead of one switch per method.
    switch (sub.subresource) {
        inline else => |subresource| {
            const Child = ChildOf(subresource);

            switch (ctx.method()) {
                // No HTML page lives at this URL: a browser asking for one gets
                // a 404 rather than being told GET is not allowed.
                .GET => if (ctx.wantsJson())
                    try respondSubCollection(ctx, zttrpg.Character, Child, sub.id)
                else
                    try ctx.notFound(),

                .PUT => try updateSubCollection(ctx, zttrpg.Character, Child, sub.id),

                else => try ctx.methodNotAllowed(),
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
    const children = ctx.db.readSubResource(ctx.gpa, Parent, Child, parent_id) catch |err|
        return ctx.respondError(err);

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
    ctx.db.updateSubResource(ctx.gpa, Parent, Child, parent_id, bodies) catch |err|
        return ctx.respondError(err);

    try ctx.respondText(.ok, "Updated {d} value(s).\n", .{bodies.len});
}

test "every resource maps to a model the handlers can serve" {
    // handleCollection and handleItem reach the database through ModelOf, so a
    // resource whose model is missing any of this would compile and then fail
    // the first time someone hit that route.
    inline for (@typeInfo(Resource).@"enum".fields) |field| {
        const Model = ModelOf(@enumFromInt(field.value));

        try std.testing.expect(@hasDecl(Model, "table_name"));
        try std.testing.expect(@hasDecl(Model, "Create"));
        try std.testing.expect(@hasDecl(Model, "Update"));

        // Every body is validated before it reaches a query.
        try std.testing.expect(@hasDecl(Model.Create, "validate"));
        try std.testing.expect(@hasDecl(Model.Update, "validate"));

        // Ids are generated by the database: an `id` on a Create type would
        // build INSERT INTO t (id, ...) and be rejected at runtime.
        try std.testing.expect(!@hasField(Model.Create, "id"));
    }
}

test "every sub-collection can be written, not only read" {
    // The PUT path reaches the database through ChildOf, Child.Body and
    // validateAll. A sub-resource whose model is missing any of them would
    // only break when someone sent a PUT, so pin it at build time instead.
    inline for (@typeInfo(SubResource).@"enum".fields) |field| {
        const Child = ChildOf(@enumFromInt(field.value));

        try std.testing.expect(@hasDecl(Child, "table_name"));
        try std.testing.expect(@hasDecl(Child, "Body"));
        try std.testing.expect(@hasDecl(Child.Body, "validateAll"));

        // The URL already names the character, so the body must not repeat it:
        // the two could disagree.
        try std.testing.expect(!@hasField(Child.Body, "character"));
    }
}
