// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const pq = @import("pq");

const Allocator = std.mem.Allocator;

const model = @import("model/model.zig");

pub const Skill = model.Skill;
pub const SkillKind = model.SkillKind;
pub const Kin = model.Kin;
pub const Character = model.Character;
pub const Icon = model.Icon;
pub const Attribute = model.Attribute;
pub const CharacterAttribute = model.CharacterAttribute;
pub const CharacterSkill = model.CharacterSkill;

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

    /// Returns the structure that descrives the table's columns for the given type T.
    fn RowOfT(comptime T: type) type {
        if (@hasDecl(T, "Row")) {
            return @field(T, "Row");
        } else {
            return T;
        }
    }

    /// Guards the queries that address a single row by `id`. A join table keyed
    /// by a composite primary key has no such column, so reject it here instead
    /// of letting Postgres reject the query at runtime.
    fn requireIdColumn(comptime T: type) void {
        const QueryType = RowOfT(T);
        if (!@hasField(QueryType, "id")) {
            @compileError(@typeName(T) ++ " cannot be addressed by id: " ++ @typeName(QueryType) ++
                " has no `id` field. A table keyed by a composite primary key needs a hand-written query.");
        }
    }

    pub fn readItem(self: *const Database, gpa: Allocator, comptime T: type, id: u32) !?T {
        comptime requireIdColumn(T);

        const QueryType = RowOfT(T);

        const cols = comptime Database.getCols(QueryType);
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

        const row = try Database.rowToT(QueryType, gpa, &result, 0);
        return try self.hydrate(T, gpa, row);
    }

    pub fn readSubResource(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Child: type, parent_id: u32) ![]Child {
        const QueryType = RowOfT(Child);

        const cols = comptime Database.getCols(QueryType);
        const query = "SELECT " ++ cols ++ " FROM " ++ Child.table_name ++ " WHERE " ++ Parent.resource_name ++ " = $1";
        const parent_id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{parent_id}, 0);
        defer gpa.free(parent_id_cstr);

        const result = try self.conn.execParams(query, &.{parent_id_cstr});
        defer result.deinit();

        const count = result.len();
        var items = try gpa.alloc(Child, count);

        for (0..count) |row| {
            const child_row = try Database.rowToT(QueryType, gpa, &result, row);
            items[row] = try self.hydrate(Child, gpa, child_row);
        }

        return items;
    }

    /// The update below binds Body's fields to $2 and $3, and getParams renders
    /// them in declaration order. Both are integers, so a reordered struct would
    /// swap the key with the value without any type error: pin the layout here.
    fn requireBodyLayout(comptime Child: type) void {
        const fields = @typeInfo(Child.Body).@"struct".fields;
        const ordered = fields.len == 2 and
            std.mem.eql(u8, fields[0].name, Child.Body.key_name) and
            std.mem.eql(u8, fields[1].name, "value");

        if (!ordered) {
            @compileError(@typeName(Child.Body) ++ " must declare `" ++ Child.Body.key_name ++
                "` then `value`: updateSubResourceQuery binds them to $2 and $3 in that order.");
        }
    }

    fn updateSubResourceQuery(comptime Parent: type, comptime Child: type) [:0]const u8 {
        requireBodyLayout(Child);

        return "UPDATE " ++ Child.table_name ++ " SET value = $3 WHERE " ++ Parent.resource_name ++ " = $1 AND " ++ Child.Body.key_name ++ " = $2";
    }

    pub fn updateSubResource(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Child: type, parent_id: u32, bodies: []const Child.Body) !void {
        const query = comptime Database.updateSubResourceQuery(Parent, Child);

        const parent_id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{parent_id}, 0);
        defer gpa.free(parent_id_cstr);

        try self.conn.beginTransaction();
        errdefer self.conn.rollbackTransaction() catch {
            std.log.err("Failed to rollback transaction: {s}", .{self.conn.errorMessage()});
        };

        for (bodies) |body| {
            const params = try Database.getParams(gpa, Child.Body, body);
            defer {
                for (params) |param| gpa.free(std.mem.span(param));
            }

            // $1 is the parent id, then Body's fields in declaration order.
            var all_params: [1 + params.len][*:0]const u8 = undefined;
            all_params[0] = parent_id_cstr;
            for (params, 0..) |param, i| {
                all_params[i + 1] = param;
            }

            const result = try self.conn.execParams(query, &all_params);
            defer result.deinit();

            if (try result.affectedRows() != 1) {
                return error.ItemNotFound;
            }
        }

        try self.conn.commitTransaction();
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

    pub fn readAllAlloc(self: *const Database, gpa: Allocator, comptime T: type, comptime where: ?[]const u8, value: ?u32) ![]T {
        const QueryType = RowOfT(T);

        // Build the SELECT query dynamically based on the fields of the struct T.
        const cols = comptime Database.getCols(QueryType);

        var result: pq.Result = undefined;

        if (where) |w| {
            const query = "SELECT " ++ cols ++ " FROM " ++ T.table_name ++ " WHERE " ++ w ++ " = $1";
            const v = value.?;
            const value_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{v}, 0);
            defer gpa.free(value_cstr);
            result = try self.conn.execParams(query, &.{value_cstr});
        } else {
            const query = "SELECT " ++ cols ++ " FROM " ++ T.table_name;
            result = try self.conn.exec(query);
        }
        defer result.deinit();

        const count = result.len();
        var items = try gpa.alloc(T, count);

        for (0..count) |row| {
            const item_row = try Database.rowToT(QueryType, gpa, &result, row);
            items[row] = try self.hydrate(T, gpa, item_row);
        }

        return items;
    }

    /// Copies one row out of the result. This is the only place a queried
    /// string is allocated: libpq frees the result buffer on PQclear, so the
    /// bytes have to be duplicated, and everything built from the row borrows
    /// that copy rather than making another. The allocator is the request's
    /// arena, so nothing here is freed individually -- see hydrate.
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

    /// Turns a stored row into the model it is served as.
    ///
    /// The query layer knows nothing about any particular model: a model whose
    /// stored shape differs from its served shape says how to bridge the two in
    /// its own `fromRow`, and this just calls it. Adding a model therefore
    /// touches only that model.
    ///
    /// Models are plain data. Their strings come straight from `row`, which
    /// rowToT already copied into `gpa`, so nothing is copied twice and nothing
    /// owns anything: `gpa` is the request's arena and the whole graph is
    /// released with it.
    fn hydrate(self: *const Database, comptime T: type, gpa: Allocator, row: RowOfT(T)) !T {
        comptime requireFromRow(T);

        // A model that declares no Row is stored exactly as it is served.
        if (comptime RowOfT(T) == T) return row;

        return T.fromRow(self, gpa, row);
    }

    /// Guards the seam above. A model that splits its stored shape from its
    /// served shape has to say how to get from one to the other; without this
    /// the omission surfaces as a missing-declaration error inside hydrate,
    /// pointing at the query layer rather than at the model that is missing it.
    fn requireFromRow(comptime T: type) void {
        if (RowOfT(T) != T and !@hasDecl(T, "fromRow")) {
            @compileError(@typeName(T) ++ " declares Row but no fromRow: the query layer" ++
                " cannot know how to turn " ++ @typeName(RowOfT(T)) ++ " into " ++ @typeName(T) ++ ".");
        }
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
        comptime requireIdColumn(T);

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
        comptime requireIdColumn(T);

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
        comptime requireIdColumn(T);

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
    // are silently skipped. This only reaches files inside this module --
    // `pq` is a module of its own, so build.zig gives it its own test step.
    _ = model;
}

/// Every model the generic query builders are expected to serve.
const all_models = .{ Character, Kin, Skill };

test "getCols lists the fields in declaration order" {
    try std.testing.expectEqualStrings("id, name, level, kin, attributes, skills", comptime Database.getCols(Character));
    try std.testing.expectEqualStrings("id, name, icon", comptime Database.getCols(Kin));
    try std.testing.expectEqualStrings("id, name, icon, kind, description", comptime Database.getCols(Skill));
    // Insert columns come from the Create type, which must never carry `id`:
    // getPlaceholders and getParams both assume every field is insertable.
    try std.testing.expectEqualStrings("name, level, kin", comptime Database.getCols(Character.Create));
    try std.testing.expectEqualStrings("name, icon", comptime Database.getCols(Kin.Create));
    try std.testing.expectEqualStrings("name, icon, kind, description", comptime Database.getCols(Skill.Create));
}

test "no Create type carries an id column" {
    // The invariant the test above spells out per model, stated once for all of
    // them: ids are generated by the database, so an `id` field on a Create type
    // would build `INSERT INTO t (id, ...) VALUES ($1, ...)` and fail against
    // the GENERATED ALWAYS AS IDENTITY columns at runtime, not at compile time.
    inline for (all_models) |Model| {
        inline for (@typeInfo(Model.Create).@"struct".fields) |field| {
            try std.testing.expect(!std.mem.eql(u8, field.name, "id"));
        }
    }
}

test "every model names the table it is stored in" {
    inline for (all_models) |Model| {
        try std.testing.expect(Model.table_name.len > 0);
    }
}

test "getPlaceholders numbers parameters from $1" {
    try std.testing.expectEqualStrings("$1, $2, $3", comptime Database.getPlaceholders(Character.Create));
    try std.testing.expectEqualStrings("$1, $2", comptime Database.getPlaceholders(Kin.Create));
    try std.testing.expectEqualStrings("$1, $2, $3, $4", comptime Database.getPlaceholders(Skill.Create));
}

test "getSetClauses derives the id placeholder from the field count" {
    // Regression guard: a hardcoded `WHERE id = $3` once broke PUT /kins/<id>,
    // because Kin.Update has one body field and its id parameter is $2.
    try std.testing.expectEqualStrings(
        "name = $1, level = $2, kin = $3 WHERE id = $4",
        comptime Database.getSetClauses(Character.Update),
    );
    try std.testing.expectEqualStrings(
        "name = $1, icon = $2 WHERE id = $3",
        comptime Database.getSetClauses(Kin.Update),
    );
    try std.testing.expectEqualStrings(
        "name = $1, icon = $2, kind = $3, description = $4 WHERE id = $5",
        comptime Database.getSetClauses(Skill.Update),
    );
}

test "updateSubResourceQuery keys the update on both halves of the composite key" {
    // These tables have no id, so the WHERE clause names the whole primary key.
    // $1 is the parent and never changes across a batch, which is why it comes
    // first even though it appears last in the text.
    try std.testing.expectEqualStrings(
        "UPDATE character_attributes SET value = $3 WHERE character = $1 AND attribute = $2",
        comptime Database.updateSubResourceQuery(Character, CharacterAttribute),
    );
    try std.testing.expectEqualStrings(
        "UPDATE character_skills SET value = $3 WHERE character = $1 AND skill = $2",
        comptime Database.updateSubResourceQuery(Character, CharacterSkill),
    );
}

test "a sub-resource body renders its params in the order the update binds them" {
    const gpa = std.testing.allocator;

    // The seam between updateSubResourceQuery and getParams: $2 is the key and
    // $3 is the value, and nothing but declaration order makes that true.
    const params = try Database.getParams(gpa, CharacterAttribute.Body, .{ .attribute = 5, .value = 9 });
    defer {
        for (params) |param| gpa.free(std.mem.span(param));
    }

    try std.testing.expectEqualStrings("5", std.mem.span(params[0]));
    try std.testing.expectEqualStrings("9", std.mem.span(params[1]));
}

test "a model without a Row type queries its own fields" {
    // Character declares Row because its `kin` column is an id on the wire but a
    // nested Kin in the struct. Skill has no such split, so RowOfT must fall
    // back to Skill itself rather than requiring every model to declare a Row.
    try std.testing.expectEqual(Skill.Row, Database.RowOfT(Skill));
    try std.testing.expectEqual(Kin.Row, Database.RowOfT(Kin));
    try std.testing.expectEqual(Icon, Database.RowOfT(Icon));
    try std.testing.expectEqual(Character.Row, Database.RowOfT(Character));
}

test "getParams renders fields as C strings in declaration order" {
    const gpa = std.testing.allocator;

    const params = try Database.getParams(gpa, Character.Create, .{ .name = "Grog", .level = 3, .kin = 1 });
    defer {
        for (params) |param| gpa.free(std.mem.span(param));
    }

    try std.testing.expectEqualStrings("Grog", std.mem.span(params[0]));
    try std.testing.expectEqualStrings("3", std.mem.span(params[1]));
    try std.testing.expectEqualStrings("1", std.mem.span(params[2]));
}

test "getParamsWithId appends the id as the final parameter" {
    const gpa = std.testing.allocator;

    // The id position must match the placeholder getSetClauses generates.
    const params = try Database.getParamsWithId(gpa, Kin.Update, .{ .name = "Elf", .icon = 1 }, 9);
    defer {
        for (params) |param| gpa.free(std.mem.span(param));
    }

    try std.testing.expectEqualStrings("Elf", std.mem.span(params[0]));
    try std.testing.expectEqualStrings("1", std.mem.span(params[1]));
}
