// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! Turning a request target into the thing it names. Nothing here touches the
//! database or the filesystem: a Route is a parsed URL and no more.

const std = @import("std");

pub const Resource = enum {
    ages,
    characters,
    kins,
    skill_kinds,
    skills,
    icons,
    attributes,
};

pub const ResourceItem = struct {
    resource: Resource,
    id: u32,
};

/// SubResource is a subset of Resource that can be used to identify sub-resources of a resource.
/// For example, a character can have attributes and skills.
pub const SubResource = enum {
    attributes,
    skills,
};

/// SubCollection represents a sub-resource collection of a resource item.
/// For example, a character can have a collection of attributes or skills.
pub const SubCollection = struct {
    resource: Resource,
    id: u32,
    subresource: SubResource,
};

pub const Route = union(enum) {
    root,
    collection: Resource,
    item: ResourceItem,
    sub_collection: SubCollection,
    static: []const u8,
    not_found,

    pub fn parseRoute(target: []const u8) Route {
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
