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

    fn getParamsWithId(gpa: Allocator, comptime T: type, item: T, id: u32) ![@typeInfo(T).@"struct".fields.len + 1][*:0]const u8 {
        const fields = @typeInfo(T).@"struct".fields;
        var params: [fields.len + 1][*:0]const u8 = undefined;

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

        params[fields.len] = try std.fmt.allocPrintSentinel(gpa, "{d}", .{id}, 0);

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

    pub fn getSetClauses(comptime T: type) []const u8 {
        comptime var set_clauses: []const u8 = "";
        const fields = @typeInfo(T).@"struct".fields;
        inline for (0..fields.len) |i| {
            const field = fields[i];
            set_clauses = set_clauses ++ field.name ++ " = $" ++ std.fmt.comptimePrint("{d}", .{i + 1});
            if (i < fields.len - 1) {
                set_clauses = set_clauses ++ ", ";
            }
        }
        set_clauses = set_clauses ++ " WHERE id = $" ++ std.fmt.comptimePrint("{d}", .{fields.len + 1});
        return set_clauses;
    }

    pub fn updateItem(self: *const Database, gpa: Allocator, comptime T: type, id: u32, item: T.Update) !void {
        const set_clauses = comptime Database.getSetClauses(T.Update);
        const query = "UPDATE " ++ T.table_name ++ " SET " ++ set_clauses;

        const params = try Database.getParamsWithId(gpa, T.Update, item, id);

        const result = try self.conn.execParams(query, &params);
        defer result.deinit();

        if (try result.affectedRows() != 1) {
            return error.ItemNotFound;
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

test {
    // Test discovery is lazy: without this reference the model files' tests
    // are silently skipped.
    _ = model;
}

test "getCols lists the fields in declaration order" {
    try std.testing.expectEqualStrings("id, name, level", comptime Database.getCols(Character));
    try std.testing.expectEqualStrings("id, name", comptime Database.getCols(Kin));
    // Insert columns come from the Create type, which must never carry `id`:
    // getPlaceholders and getParams both assume every field is insertable.
    try std.testing.expectEqualStrings("name, level", comptime Database.getCols(Character.Create));
    try std.testing.expectEqualStrings("name", comptime Database.getCols(Kin.Create));
}

test "getPlaceholders numbers parameters from $1" {
    try std.testing.expectEqualStrings("$1, $2", comptime Database.getPlaceholders(Character.Create));
    try std.testing.expectEqualStrings("$1", comptime Database.getPlaceholders(Kin.Create));
}

test "getSetClauses derives the id placeholder from the field count" {
    // Regression guard: a hardcoded `WHERE id = $3` once broke PUT /kins/<id>,
    // because Kin.Update has one body field and its id parameter is $2.
    try std.testing.expectEqualStrings(
        "name = $1, level = $2 WHERE id = $3",
        comptime Database.getSetClauses(Character.Update),
    );
    try std.testing.expectEqualStrings(
        "name = $1 WHERE id = $2",
        comptime Database.getSetClauses(Kin.Update),
    );
}

test "getParams renders fields as C strings in declaration order" {
    const gpa = std.testing.allocator;

    const params = try Database.getParams(gpa, Character.Create, .{ .name = "Grog", .level = 3 });
    defer {
        for (params) |param| gpa.free(std.mem.span(param));
    }

    try std.testing.expectEqualStrings("Grog", std.mem.span(params[0]));
    try std.testing.expectEqualStrings("3", std.mem.span(params[1]));
}

test "getParamsWithId appends the id as the final parameter" {
    const gpa = std.testing.allocator;

    // The id position must match the placeholder getSetClauses generates.
    const params = try Database.getParamsWithId(gpa, Kin.Update, .{ .name = "Elf" }, 9);
    defer {
        for (params) |param| gpa.free(std.mem.span(param));
    }

    try std.testing.expectEqualStrings("Elf", std.mem.span(params[0]));
    try std.testing.expectEqualStrings("9", std.mem.span(params[1]));
}
