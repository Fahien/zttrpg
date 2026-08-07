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

    pub fn readItem(self: *const Database, gpa: Allocator, comptime T: type, id: u32) !?T {
        const cols = comptime Database.getCols(T);
        const query = "SELECT " ++ cols ++ " FROM " ++ T.table_name ++ " WHERE id = $1";
        const id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{id}, 0);
        defer gpa.free(id_cstr);

        const result = try self.conn.execParams(query, &.{id_cstr});
        defer result.deinit();

        if (result.len() == 0) {
            return null;
        } else if (result.len() != 1) {
            return error.UnexpectedResult;
        }

        return try Database.rowToT(T, gpa, &result, 0);
    }

    fn getCols(comptime T: type) []const u8 {
        comptime var cols: []const u8 = "";
        const field_count = @typeInfo(T).@"struct".fields.len;
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            cols = cols ++ field.name;
            if (i < field_count - 1) {
                cols = cols ++ ", ";
            }
        }
        return cols;
    }

    fn getColsWithoutId(comptime T: type) []const u8 {
        comptime var cols: []const u8 = "";
        const field_count = @typeInfo(T).@"struct".fields.len;
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            if (!std.mem.eql(u8, field.name, "id")) {
                cols = cols ++ field.name;
                if (i < field_count - 1) {
                    cols = cols ++ ", ";
                }
            }
        }
        return cols;
    }

    pub fn readAllAlloc(self: *const Database, gpa: Allocator, comptime T: type) ![]T {
        // Build the SELECT query dynamically based on the fields of the struct T.
        const cols = comptime Database.getCols(T);
        const query = "SELECT " ++ cols ++ " FROM " ++ T.table_name;
        const result = try self.conn.exec(query);
        defer result.deinit();

        const count = result.len();
        var items = try gpa.alloc(T, count);

        for (0..count) |row| {
            items[row] = try Database.rowToT(T, gpa, &result, row);
        }

        return items;
    }

    fn rowToT(comptime T: type, gpa: Allocator, result: *const pq.Result, row: usize) !T {
        var ret: T = undefined;

        inline for (@typeInfo(T).@"struct".fields, 0..) |field, col_index| {
            const col_value_cstr = result.getValue(row, col_index);
            const col_value_str = std.mem.span(col_value_cstr);

            const type_info = @typeInfo(field.type);
            switch (type_info) {
                .int => {
                    const field_value = try std.fmt.parseInt(field.type, col_value_str, 10);
                    @field(ret, field.name) = field_value;
                },
                .pointer => {
                    if (type_info.pointer.child == u8) {
                        const field_value = try gpa.dupe(u8, col_value_str);
                        @field(ret, field.name) = field_value;
                    } else {
                        @compileError("Unsupported pointer type: " ++ @typeName(field.type));
                    }
                },
                else => @compileError("Unsupported field type: " ++ @typeName(field.type)),
            }
        }
        return ret;
    }

    pub fn getPlaceholders(comptime T: type) []const u8 {
        comptime var placeholders: []const u8 = "";
        const fields = @typeInfo(T).@"struct".fields;
        inline for (0..fields.len) |placeholder_index| {
            placeholders = placeholders ++ "$" ++ std.fmt.comptimePrint("{d}", .{placeholder_index + 1});
            if (placeholder_index < fields.len - 1) {
                placeholders = placeholders ++ ", ";
            }
        }
        return placeholders;
    }

    fn getParams(gpa: Allocator, comptime T: type, item: T) ![@typeInfo(T).@"struct".fields.len][*:0]const u8 {
        const fields = @typeInfo(T).@"struct".fields;
        var params: [fields.len][*:0]const u8 = undefined;

        inline for (fields, 0..) |field, i| {
            switch (@typeInfo(field.type)) {
                .int => {
                    const field_value = @field(item, field.name);
                    params[i] = try std.fmt.allocPrintSentinel(gpa, "{d}", .{field_value}, 0);
                },
                .pointer => {
                    if (@typeInfo(field.type).pointer.child == u8) {
                        const field_value = @field(item, field.name);
                        params[i] = try gpa.dupeZ(u8, field_value);
                    } else {
                        @compileError("Unsupported pointer type: " ++ @typeName(field.type));
                    }
                },
                else => @compileError("Unsupported field type: " ++ @typeName(field.type)),
            }
        }

        return params;
    }

    pub fn insertItem(self: *const Database, gpa: Allocator, comptime T: type, item: T.Create) !u32 {
        const cols = comptime Database.getCols(T.Create);
        const placeholders = comptime Database.getPlaceholders(T.Create);

        const query = "INSERT INTO " ++ T.table_name ++ " (" ++ cols ++ ") VALUES (" ++ placeholders ++ ") RETURNING id";

        const params = try Database.getParams(gpa, T.Create, item);

        const result = try self.conn.execParams(query, &params);
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

    pub fn deleteItem(self: *const Database, gpa: Allocator, comptime T: type, id: u32) !void {
        const query = "DELETE FROM " ++ T.table_name ++ " WHERE id = $1";

        const id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{id}, 0);
        defer gpa.free(id_cstr);

        const result = try self.conn.execParams(query, &.{id_cstr});
        defer result.deinit();

        if (try result.affectedRows() != 1) {
            return error.ItemNotFound;
        }
    }
};
