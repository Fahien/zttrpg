// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Icon = @import("icon.zig").Icon;

pub const AttributeBody = struct {
    name: []const u8,
    icon: Icon.Id,
    short: []const u8,
    description: []const u8,

    pub fn validate(self: *const AttributeBody) !void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.short.len == 0) return error.EmptyShort;
    }
};

pub const AttributeCreate = AttributeBody;
pub const AttributeUpdate = AttributeBody;

pub const AttributeRow = struct {
    id: Attribute.Id,
    name: []const u8,
    icon: Icon.Id,
    short: []const u8,
    description: []const u8,
};

pub const Attribute = struct {
    pub const Id = u32;
    pub const Create = AttributeCreate;
    pub const Update = AttributeUpdate;
    pub const Row = AttributeRow;
    pub const table_name: []const u8 = "attributes";

    id: Id = 0,
    name: []const u8,
    icon: Icon,
    short: []const u8,
    description: []const u8,

    pub fn init(gpa: Allocator, id: u32, name: []const u8, icon: Icon, short: []const u8, description: []const u8) !Attribute {
        const name_copy = try gpa.dupe(u8, name);
        const description_copy = try gpa.dupe(u8, description);
        return Attribute{
            .id = id,
            .name = name_copy,
            .icon = icon,
            .short = try gpa.dupe(u8, short),
            .description = description_copy,
        };
    }

    pub fn deinit(self: *const Attribute, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.short);
        gpa.free(self.description);
    }
};

test "AttributeCreate.validate accepts a well-formed Attribute" {
    const attribute = AttributeCreate{ .name = "Stealth", .icon = 1, .short = "STL.", .description = "Expertise in moving unseen." };
    try attribute.validate();
}

test "AttributeCreate.validate rejects an empty name" {
    const attribute = AttributeCreate{ .name = "", .icon = 1, .short = "", .description = "" };
    try std.testing.expectError(error.EmptyName, attribute.validate());
}

test "Attribute serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const attribute = Attribute{ .id = 1, .name = "Stealth", .icon = Icon{ .id = 1, .name = "abacus" }, .short = "STL.", .description = "Expertise in moving unseen." };
    try std.json.Stringify.value(attribute, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Stealth","icon":{"id":1,"name":"abacus"},"short":"STL.","description":"Expertise in moving unseen."}
    , out.written());
}

test "AttributeCreate parses from a JSON body" {
    // The shape POST /attributes receives: no id, because the database assigns it.
    const parsed = try std.json.parseFromSlice(
        AttributeCreate,
        std.testing.allocator,
        \\{"name":"Stealth","icon":1,"short":"STL.","description":"Expertise in moving unseen."}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Stealth", parsed.value.name);
}

test "Attribute.init copies the name and deinit frees it" {
    const gpa = std.testing.allocator;

    var name_buf = [_]u8{ 'H', 'e', 'a', 'l' };
    const attribute = try Attribute.init(gpa, 7, &name_buf, Icon{ .id = 1, .name = "abacus" }, "STL.", "Expertise in moving unseen.");
    defer attribute.deinit(gpa);

    // Mutating the source must not affect the copy.
    name_buf[0] = 'S';
    try std.testing.expectEqualStrings("Heal", attribute.name);
    try std.testing.expectEqual(7, attribute.id);
}
