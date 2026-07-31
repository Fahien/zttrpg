// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const pq = @import("pq");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const CreateCharacter = struct {
    name: []const u8,
    level: u32,

    // Mirrors the CHECK constraints in db/0001-characters.sql: the database
    // enforces integrity, this gives clients a 400 instead of a 500.
    pub fn validate(self: *const CreateCharacter) error{ EmptyName, LevelOutOfRange }!void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.level < 1 or self.level > 100) return error.LevelOutOfRange;
    }
};

pub const DeleteCharacter = struct {
    id: u32,
};

pub const Character = struct {
    id: u32,
    name: []const u8,
    level: u32,

    pub fn init(gpa: Allocator, id: u32, name: []const u8, level: u32) !Character {
        const name_copy = try gpa.dupe(u8, name);
        return Character{
            .id = id,
            .name = name_copy,
            .level = level,
        };
    }

    pub fn deinit(self: *const Character, gpa: Allocator) void {
        gpa.free(self.name);
    }
};

pub const Database = struct {
    conn: pq.Connection,

    pub fn init() !Database {
        const conn = try pq.Connection.connect("dbname=zttrpg");
        return Database{
            .conn = conn,
        };
    }

    pub fn deinit(self: *const Database) void {
        self.conn.close();
    }

    pub fn readCharacter(self: *const Database, gpa: Allocator, id: u32) !?Character {
        const query = "SELECT id, name, level FROM characters WHERE id = $1";
        const id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{id}, 0);
        defer gpa.free(id_cstr);

        const result = try self.conn.execParams(query, &.{id_cstr});
        defer result.deinit();

        if (result.len() == 0) {
            return null;
        } else if (result.len() != 1) {
            return error.UnexpectedResult;
        }

        const id_cstr_result = result.getValue(0, 0);
        const name_cstr = result.getValue(0, 1);
        const level_cstr = result.getValue(0, 2);

        const id_str = std.mem.span(id_cstr_result);
        const name_str = std.mem.span(name_cstr);
        const level_str = std.mem.span(level_cstr);

        const id_parsed = try std.fmt.parseInt(u32, id_str, 10);
        const level_parsed = try std.fmt.parseInt(u32, level_str, 10);

        return try Character.init(gpa, id_parsed, name_str, level_parsed);
    }

    pub fn readCharactersAlloc(self: *const Database, gpa: Allocator) ![]Character {
        const result = try self.conn.exec("SELECT id, name, level FROM characters");
        defer result.deinit();

        const count = result.len();
        var characters = try gpa.alloc(Character, count);

        for (0..count) |i| {
            const id_cstr = result.getValue(i, 0);
            const name_cstr = result.getValue(i, 1);
            const level_cstr = result.getValue(i, 2);

            const id_str = std.mem.span(id_cstr);
            const name_str = std.mem.span(name_cstr);
            const level_str = std.mem.span(level_cstr);

            const id = try std.fmt.parseInt(u32, id_str, 10);
            const level = try std.fmt.parseInt(u32, level_str, 10);

            characters[i] = try Character.init(gpa, id, name_str, level);
        }

        return characters;
    }

    pub fn insertCharacter(self: *const Database, gpa: Allocator, character: CreateCharacter) !u32 {
        const query = "INSERT INTO characters (name, level) VALUES ($1, $2) RETURNING id";

        const name_cstr = try gpa.dupeZ(u8, character.name);
        defer gpa.free(name_cstr);

        const level_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{character.level}, 0);
        defer gpa.free(level_cstr);

        const result = try self.conn.execParams(query, &.{ name_cstr, level_cstr });
        defer result.deinit();

        if (result.len() != 1) {
            return error.UnexpectedResult;
        }
        const id_cstr = result.getValue(0, 0);
        const id_str = std.mem.span(id_cstr);
        const id = try std.fmt.parseInt(u32, id_str, 10);
        return id;
    }

    pub fn deleteCharacter(self: *const Database, gpa: Allocator, character: DeleteCharacter) !void {
        const query = "DELETE FROM characters WHERE id = $1";

        const id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{character.id}, 0);
        defer gpa.free(id_cstr);

        const result = try self.conn.execParams(query, &.{id_cstr});
        defer result.deinit();

        if (try result.affectedRows() != 1) {
            return error.CharacterNotFound;
        }
    }
};

test "Character.init copies the name and deinit frees it" {
    const gpa = std.testing.allocator;

    var name_buf = [_]u8{ 'G', 'r', 'o', 'g' };
    const character = try Character.init(gpa, 7, &name_buf, 3);
    defer character.deinit(gpa);

    // Mutating the source must not affect the copy.
    name_buf[0] = 'F';
    try std.testing.expectEqualStrings("Grog", character.name);
    try std.testing.expectEqual(7, character.id);
    try std.testing.expectEqual(3, character.level);
}

test "CreateCharacter.validate accepts a well-formed character" {
    const character = CreateCharacter{ .name = "Grog", .level = 1 };
    try character.validate();
}

test "CreateCharacter.validate rejects an empty name" {
    const character = CreateCharacter{ .name = "", .level = 3 };
    try std.testing.expectError(error.EmptyName, character.validate());
}

test "CreateCharacter.validate rejects levels out of range" {
    const zero = CreateCharacter{ .name = "Grog", .level = 0 };
    try std.testing.expectError(error.LevelOutOfRange, zero.validate());

    const too_high = CreateCharacter{ .name = "Grog", .level = 101 };
    try std.testing.expectError(error.LevelOutOfRange, too_high.validate());

    const max = CreateCharacter{ .name = "Grog", .level = 100 };
    try max.validate();
}

test "Character serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const character = Character{ .id = 1, .name = "Alice", .level = 2 };
    try std.json.Stringify.value(character, .{}, &out.writer);

    try std.testing.expectEqualStrings(
        \\{"id":1,"name":"Alice","level":2}
    , out.written());
}

test "CreateCharacter parses from a JSON body" {
    const parsed = try std.json.parseFromSlice(
        CreateCharacter,
        std.testing.allocator,
        \\{"name":"Grog","level":3}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Grog", parsed.value.name);
    try std.testing.expectEqual(3, parsed.value.level);
}
