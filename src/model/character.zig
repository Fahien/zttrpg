// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Kin = @import("kin.zig").Kin;

pub const BodyCharacter = struct {
    name: []const u8,
    level: u32,
    kin: Kin.Id,

    // Mirrors the CHECK constraints in db/0001-characters.sql: the database
    // enforces integrity, this gives clients a 400 instead of a 500.
    pub fn validate(self: *const BodyCharacter) error{ EmptyName, LevelOutOfRange }!void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.level < 1 or self.level > 100) return error.LevelOutOfRange;
    }
};

pub const CreateCharacter = BodyCharacter;
pub const UpdateCharacter = BodyCharacter;
pub const RowCharacter = struct {
    id: Character.Id,
    name: []const u8,
    level: u32,
    kin: Kin.Id,
};

pub const Character = struct {
    pub const Id = u32;
    pub const Create = CreateCharacter;
    pub const Update = UpdateCharacter;
    pub const Row = RowCharacter;

    pub const table_name: []const u8 = "characters";

    id: Id,
    name: []const u8,
    level: u32,
    kin: Kin,

    pub fn init(gpa: Allocator, id: u32, name: []const u8, level: u32, kin: Kin) !Character {
        const name_copy = try gpa.dupe(u8, name);
        return Character{
            .id = id,
            .name = name_copy,
            .level = level,
            .kin = kin,
        };
    }

    pub fn deinit(self: *const Character, gpa: Allocator) void {
        gpa.free(self.name);
    }
};

test "Character.init copies the name and deinit frees it" {
    const gpa = std.testing.allocator;

    var name_buf = [_]u8{ 'G', 'r', 'o', 'g' };
    const kin = Kin{ .id = 1, .name = "Elf", .icon = .{ .id = 1, .name = "abacus" } };
    const character = try Character.init(gpa, 7, &name_buf, 3, kin);
    defer character.deinit(gpa);

    // Mutating the source must not affect the copy.
    name_buf[0] = 'F';
    try std.testing.expectEqualStrings("Grog", character.name);
    try std.testing.expectEqual(7, character.id);
    try std.testing.expectEqual(3, character.level);
}

test "CreateCharacter.validate accepts a well-formed character" {
    const character = CreateCharacter{ .name = "Grog", .level = 1, .kin = 1 };
    try character.validate();
}

test "CreateCharacter.validate rejects an empty name" {
    const character = CreateCharacter{ .name = "", .level = 3, .kin = 1 };
    try std.testing.expectError(error.EmptyName, character.validate());
}

test "CreateCharacter.validate rejects levels out of range" {
    const zero = CreateCharacter{ .name = "Grog", .level = 0, .kin = 1 };
    try std.testing.expectError(error.LevelOutOfRange, zero.validate());

    const too_high = CreateCharacter{ .name = "Grog", .level = 101, .kin = 1 };
    try std.testing.expectError(error.LevelOutOfRange, too_high.validate());

    const max = CreateCharacter{ .name = "Grog", .level = 100, .kin = 1 };
    try max.validate();
}

test "Character serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const kin = Kin{ .id = 1, .name = "Elf", .icon = .{ .id = 1, .name = "abacus" } };
    const character = Character{ .id = 1, .name = "Alice", .level = 2, .kin = kin };
    try std.json.Stringify.value(character, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2,"kin":{"id":1,"name":"Elf","icon":{"id":1,"name":"abacus"}}}
    , out.written());
}

test "CreateCharacter parses from a JSON body" {
    const parsed = try std.json.parseFromSlice(
        CreateCharacter,
        std.testing.allocator,
        \\{"name":"Grog","level":3,"kin":1}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Grog", parsed.value.name);
    try std.testing.expectEqual(3, parsed.value.level);
}
