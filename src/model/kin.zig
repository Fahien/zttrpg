// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const KinBody = struct {
    name: []const u8,

    pub fn validate(self: *const KinBody) error{EmptyName}!void {
        if (self.name.len == 0) return error.EmptyName;
    }
};

pub const KinCreate = KinBody;
pub const KinUpdate = KinBody;

pub const Kin = struct {
    pub const Id = u32;
    pub const Create = KinCreate;
    pub const Update = KinUpdate;
    pub const table_name: []const u8 = "kins";

    id: Id = 0,
    name: []const u8,

    pub fn init(gpa: Allocator, id: u32, name: []const u8) !Kin {
        const name_copy = try gpa.dupe(u8, name);
        return Kin{
            .id = id,
            .name = name_copy,
        };
    }

    pub fn deinit(self: *const Kin, gpa: Allocator) void {
        gpa.free(self.name);
    }
};

test "KinCreate.validate accepts a well-formed kin" {
    const kin = KinCreate{ .name = "Elf" };
    try kin.validate();
}

test "KinCreate.validate rejects an empty name" {
    const kin = KinCreate{ .name = "" };
    try std.testing.expectError(error.EmptyName, kin.validate());
}

test "Kin serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const kin = Kin{ .id = 1, .name = "Elf" };
    try std.json.Stringify.value(kin, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Elf"}
    , out.written());
}
