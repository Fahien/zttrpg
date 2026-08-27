// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! Serving what a browser asks for: HTML pages assembled from partials, and
//! the static files they reference.
//!
//! Pages are read from disk on every request rather than embedded, so editing
//! a file in src/web and refreshing the browser is enough -- no rebuild.

const std = @import("std");

const Context = @import("context.zig").Context;
const Resource = @import("route.zig").Resource;

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Which of a resource's two pages to serve: the roster or one instance.
pub const Page = enum { index, item };

/// The directory every page and asset is read from, relative to the working
/// directory, which is why the server has to be run from the repository root.
const web_root = "src/web";

/// Pages and assets are small; this bounds a single read.
const max_file_size = 4096 * 16;
const max_partial_size = 4096;

/// The site's front page.
pub fn serveIndex(ctx: *Context) !void {
    try servePage(ctx, "index.html", "ZTTRPG");
}

/// The page for a resource: /characters serves characters/index.html, and
/// /characters/3 serves characters/item.html. Which record it shows is the
/// page's own business -- its script reads the id back out of the URL.
pub fn serveResource(ctx: *Context, resource: Resource, page: Page) !void {
    const sub_path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}.html", .{ @tagName(resource), @tagName(page) });

    const title = try std.fmt.allocPrint(ctx.gpa, "ZTTRPG - {s}", .{@tagName(resource)});
    title[0] = std.ascii.toUpper(title[0]);

    try servePage(ctx, sub_path, title);
}

/// A file served as-is, under the content type its extension implies.
pub fn serveStatic(ctx: *Context, sub_path: []const u8) !void {
    var web_dir = try Io.Dir.cwd().openDir(ctx.io, web_root, .{});
    defer web_dir.close(ctx.io);

    const file_content = readFile(ctx, web_dir, sub_path, max_file_size) catch {
        return ctx.notFound();
    };

    try ctx.respondBytes(contentTypeOf(sub_path), file_content);
}

/// A page with the shared partials substituted into it.
fn servePage(ctx: *Context, sub_path: []const u8, title: []const u8) !void {
    var web_dir = try Io.Dir.cwd().openDir(ctx.io, web_root, .{});
    defer web_dir.close(ctx.io);

    // A missing page is a 404: the request named something that is not there.
    var content = readFile(ctx, web_dir, sub_path, max_file_size) catch {
        return ctx.notFound();
    };

    // A missing partial is different: every page needs them, so the page that
    // was asked for does exist and this server cannot assemble it.
    inline for (.{ "head", "header", "footer" }) |name| {
        const partial = readFile(ctx, web_dir, "partials/" ++ name ++ ".html", max_partial_size) catch {
            return ctx.respondError(error.PartialMissing);
        };
        content = try replace(ctx.gpa, content, "{{" ++ name ++ "}}", partial);
    }

    content = try replace(ctx.gpa, content, "{{title}}", title);

    try ctx.respondBytes("text/html", content);
}

fn readFile(ctx: *Context, dir: Io.Dir, sub_path: []const u8, limit: usize) ![]u8 {
    return dir.readFileAlloc(ctx.io, sub_path, ctx.gpa, .limited(limit)) catch |err| {
        std.debug.print("Failed to read {s}/{s}: {}\n", .{ web_root, sub_path, err });
        return err;
    };
}

fn contentTypeOf(sub_path: []const u8) []const u8 {
    const types = .{
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".html", "text/html" },
        .{ ".svg", "image/svg+xml" },
    };

    inline for (types) |entry| {
        if (std.mem.endsWith(u8, sub_path, entry[0])) return entry[1];
    }
    return "text/plain";
}

/// Substitutes every occurrence of `placeholder`, returning a new buffer. The
/// allocator is the request's arena, so the intermediate copies each pass
/// leaves behind are released with the connection.
fn replace(gpa: Allocator, source: []const u8, placeholder: []const u8, replacement: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, source, placeholder, replacement);
    const buffer = try gpa.alloc(u8, size);
    _ = std.mem.replace(u8, source, placeholder, replacement, buffer);
    return buffer;
}

test "content type follows the extension, and is text by default" {
    try std.testing.expectEqualStrings("text/css", contentTypeOf("static/custom.css"));
    try std.testing.expectEqualStrings("application/javascript", contentTypeOf("static/roster.js"));
    try std.testing.expectEqualStrings("image/svg+xml", contentTypeOf("static/icons/abacus.svg"));
    try std.testing.expectEqualStrings("text/html", contentTypeOf("characters/index.html"));
    // An extension nobody listed must not be guessed at.
    try std.testing.expectEqualStrings("text/plain", contentTypeOf("static/robots.txt"));
    try std.testing.expectEqualStrings("text/plain", contentTypeOf("static/noextension"));
}

test "replace substitutes every occurrence" {
    const gpa = std.testing.allocator;

    const once = try replace(gpa, "a {{x}} b", "{{x}}", "Y");
    defer gpa.free(once);
    try std.testing.expectEqualStrings("a Y b", once);

    // A page may name the same partial twice.
    const twice = try replace(gpa, "{{x}}/{{x}}", "{{x}}", "Y");
    defer gpa.free(twice);
    try std.testing.expectEqualStrings("Y/Y", twice);

    // A placeholder nothing mentions leaves the page alone.
    const absent = try replace(gpa, "nothing here", "{{x}}", "Y");
    defer gpa.free(absent);
    try std.testing.expectEqualStrings("nothing here", absent);
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

test "every page substitutes the partials this file writes in" {
    // servePage names these three; a page that spells one differently would
    // render with a literal {{header}} in it and nothing would fail.
    inline for (@typeInfo(Resource).@"enum".fields) |resource| {
        inline for (.{ "index", "item" }) |page| {
            const html = @embedFile("web/" ++ resource.name ++ "/" ++ page ++ ".html");
            inline for (.{ "{{head}}", "{{header}}", "{{footer}}" }) |placeholder| {
                if (std.mem.find(u8, html, placeholder) == null) {
                    std.debug.print("{s}/{s}.html is missing {s}\n", .{ resource.name, page, placeholder });
                    return error.MissingPlaceholder;
                }
            }
        }
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
