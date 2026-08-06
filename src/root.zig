// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const pq = @import("pq");

const Allocator = std.mem.Allocator;

const model = @import("model/model.zig");

pub const Kin = model.Kin;
pub const BodyCharacter = model.BodyCharacter;
pub const CreateCharacter = model.CreateCharacter;
pub const UpdateCharacter = model.UpdateCharacter;
pub const Character = model.Character;

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

        return try Database.rowToCharacter(gpa, &result, 0);
    }

    pub fn readKinsAlloc(self: *const Database, gpa: Allocator) ![]Kin {
        const result = try self.conn.exec("SELECT id, name FROM kins");
        defer result.deinit();

        const count = result.len();
        var kins = try gpa.alloc(Kin, count);

        for (0..count) |row| {
            kins[row] = try Database.rowToKin(gpa, &result, row);
        }

        return kins;
    }

    fn rowToKin(gpa: Allocator, result: *const pq.Result, row: usize) !Kin {
        const id_cstr = result.getValue(row, 0);
        const name_cstr = result.getValue(row, 1);

        const id_str = std.mem.span(id_cstr);
        const name_str = std.mem.span(name_cstr);

        const id_parsed = try std.fmt.parseInt(u32, id_str, 10);

        return try Kin.init(gpa, id_parsed, name_str);
    }

    pub fn readCharactersAlloc(self: *const Database, gpa: Allocator) ![]Character {
        const result = try self.conn.exec("SELECT id, name, level FROM characters");
        defer result.deinit();

        const count = result.len();
        var characters = try gpa.alloc(Character, count);

        for (0..count) |row| {
            characters[row] = try Database.rowToCharacter(gpa, &result, row);
        }

        return characters;
    }

    fn rowToCharacter(gpa: Allocator, result: *const pq.Result, row: usize) !Character {
        const id_cstr = result.getValue(row, 0);
        const name_cstr = result.getValue(row, 1);
        const level_cstr = result.getValue(row, 2);

        const id_str = std.mem.span(id_cstr);
        const name_str = std.mem.span(name_cstr);
        const level_str = std.mem.span(level_cstr);

        const id_parsed = try std.fmt.parseInt(u32, id_str, 10);
        const level_parsed = try std.fmt.parseInt(u32, level_str, 10);

        return try Character.init(gpa, id_parsed, name_str, level_parsed);
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

    pub fn updateCharacter(self: *const Database, gpa: Allocator, id: u32, character: UpdateCharacter) !void {
        const query = "UPDATE characters SET name = $1, level = $2 WHERE id = $3";

        const name_cstr = try gpa.dupeZ(u8, character.name);
        defer gpa.free(name_cstr);

        const level_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{character.level}, 0);
        defer gpa.free(level_cstr);

        const id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{id}, 0);
        defer gpa.free(id_cstr);

        const result = try self.conn.execParams(query, &.{ name_cstr, level_cstr, id_cstr });
        defer result.deinit();

        if (try result.affectedRows() != 1) {
            return error.CharacterNotFound;
        }
    }

    pub fn deleteCharacter(self: *const Database, gpa: Allocator, id: u32) !void {
        const query = "DELETE FROM characters WHERE id = $1";

        const id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{id}, 0);
        defer gpa.free(id_cstr);

        const result = try self.conn.execParams(query, &.{id_cstr});
        defer result.deinit();

        if (try result.affectedRows() != 1) {
            return error.CharacterNotFound;
        }
    }
};
