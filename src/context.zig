// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! What every handler needs to answer one request, and the ways of answering.

const std = @import("std");
const zttrpg = @import("zttrpg");
const locked = @import("locked.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Locked = locked.Locked;

const json_content_type = std.http.Header{ .name = "Content-Type", .value = "application/json" };

/// One request, start to finish: where to allocate, what to answer with, and
/// the connection to answer on. Handlers take a `*Context` instead of threading
/// the same four values through every signature.
///
/// Everything is allocated in `gpa`, which is an arena the server resets when
/// the connection closes, so nothing here is freed by hand.
pub const Context = struct {
    gpa: Allocator,
    io: Io,
    db: *Locked(zttrpg.Database),
    request: *std.http.Server.Request,

    /// The response body, accumulated before it is handed to `request.respond`.
    /// Held by value: a Context is created once per connection and never moved,
    /// and the writer's vtable finds it back through this field.
    writer: Io.Writer.Allocating,

    pub fn init(
        gpa: Allocator,
        io: Io,
        db: *Locked(zttrpg.Database),
        request: *std.http.Server.Request,
    ) Context {
        return .{
            .gpa = gpa,
            .io = io,
            .db = db,
            .request = request,
            .writer = Io.Writer.Allocating.init(gpa),
        };
    }

    pub fn method(ctx: *const Context) std.http.Method {
        return ctx.request.head.method;
    }

    /// Whether the client asked for JSON rather than a page. The comparison is
    /// exact, so a browser's `text/html,...` Accept correctly reads as "no".
    pub fn wantsJson(ctx: *const Context) bool {
        var headers = ctx.request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.mem.eql(u8, header.name, "Accept") and
                std.mem.eql(u8, header.value, "application/json"))
            {
                return true;
            }
        }
        return false;
    }

    /// Reads the request body, up to `limit` bytes.
    ///
    /// Note that this invalidates `request.head.target`: see respondError.
    /// Exceeding the limit surfaces as error.StreamTooLong, which the mapping
    /// below turns into a 413 rather than dropping the connection.
    pub fn readBody(ctx: *Context, limit: usize) ![]u8 {
        const scratch_buffer = try ctx.gpa.alloc(u8, 4096);
        const reader = try ctx.request.readerExpectContinue(scratch_buffer);
        return reader.allocRemaining(ctx.gpa, .limited(limit));
    }

    pub fn respondJson(ctx: *Context, value: anytype) !void {
        try std.json.Stringify.value(value, .{}, &ctx.writer.writer);
        try ctx.request.respond(ctx.writer.written(), .{
            .keep_alive = false,
            .extra_headers = &.{json_content_type},
        });
    }

    /// Answers with a file's bytes under its own content type.
    pub fn respondBytes(ctx: *Context, content_type: []const u8, bytes: []const u8) !void {
        try ctx.writer.writer.print("{s}", .{bytes});
        try ctx.request.respond(ctx.writer.written(), .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Type", .value = content_type }},
        });
    }

    pub fn respondText(
        ctx: *Context,
        status: std.http.Status,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try ctx.writer.writer.print(format, args);
        try ctx.request.respond(ctx.writer.written(), .{ .status = status, .keep_alive = false });
    }

    /// Answers a failed request. The client gets a stable message and the real
    /// error goes to the log, so internal names never travel over the wire.
    pub fn respondError(ctx: *Context, err: anyerror) !void {
        const response = responseForError(err, ctx.method());

        // Not request.head.target: reading a body calls Head.invalidateStrings,
        // which sets target to undefined, and printing it then crashes the
        // server. The target is already on the "Received request" line above
        // this one. `method` survives, being an enum rather than a slice into
        // the buffer.
        std.debug.print("{} -> {d}: {}\n", .{
            ctx.method(),
            @intFromEnum(response.status),
            err,
        });

        try ctx.respondText(response.status, "{s}\n", .{response.message});
    }

    pub fn notFound(ctx: *Context) !void {
        try ctx.respondText(.not_found, "404 Not Found\n", .{});
    }

    pub fn methodNotAllowed(ctx: *Context) !void {
        try ctx.respondText(.method_not_allowed, "Method {} not allowed for this path.\n", .{ctx.method()});
    }
};

pub const ErrorResponse = struct {
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
pub fn responseForError(err: anyerror, method: std.http.Method) ErrorResponse {
    return switch (err) {
        error.ItemNotFound => .{ .status = .not_found, .message = "Not found." },

        error.InvalidJsonBody => .{ .status = .bad_request, .message = "Invalid JSON body." },

        error.StreamTooLong => .{
            .status = .payload_too_large,
            .message = "The request body is too large.",
        },

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
        error.EmptyValue,
        error.MovementOutOfRange,
        error.BandOutOfOrder,
        error.LevelOutOfRange,
        error.ValueOutOfRange,
        error.DuplicateEntry,
        => .{ .status = .bad_request, .message = "The request body is not valid." },

        else => .{ .status = .internal_server_error, .message = "Internal server error." },
    };
}

test "a foreign key violation is the client's fault either way, but not the same fault" {
    // The same SQLSTATE means "you named a row that does not exist" on a write
    // and "rows still point at this one" on a delete.
    try std.testing.expectEqual(
        std.http.Status.bad_request,
        responseForError(error.ForeignKeyViolation, .POST).status,
    );
    try std.testing.expectEqual(
        std.http.Status.conflict,
        responseForError(error.ForeignKeyViolation, .DELETE).status,
    );
}

test "an unmapped error is the server's fault" {
    // The default has to stay a 500: inventing a 4xx for an error nobody has
    // classified would blame the client for a bug here.
    try std.testing.expectEqual(
        std.http.Status.internal_server_error,
        responseForError(error.SomethingNobodyMapped, .GET).status,
    );
}
