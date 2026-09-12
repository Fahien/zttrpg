// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const pq = @import("pq");

const Allocator = std.mem.Allocator;

// The query layer is generic: nothing below names a model. These are here so
// the tests can build queries for real models and pin the SQL they produce.
const model = @import("model/model.zig");

const Character = model.Character;
const CharacterAttribute = model.CharacterAttribute;
const CharacterSkill = model.CharacterSkill;
const Icon = model.Icon;
const Item = model.Item;
const Kin = model.Kin;
const MovementModifier = model.MovementModifier;
const Profession = model.Profession;
const Skill = model.Skill;

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

    /// Reads the columns of `Projection` from one row of T's table, without
    /// hydrating anything. A model that needs part of a record on a write path
    /// names the columns it reads, rather than paying readItem's nested
    /// queries for a record nobody serves.
    pub fn readProjection(self: *const Database, gpa: Allocator, comptime T: type, comptime Projection: type, id: u32) !?Projection {
        comptime requireIdColumn(T);

        const cols = comptime Database.getCols(Projection);
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

        return try Database.rowToT(Projection, gpa, &result, 0);
    }

    pub fn readItem(self: *const Database, gpa: Allocator, comptime T: type, id: u32) !?T {
        const row = (try self.readProjection(gpa, T, RowOfT(T), id)) orelse return null;
        return try self.hydrate(T, gpa, row);
    }

    fn readRelatedQuery(comptime Parent: type, comptime Target: type, comptime Link: type) [:0]const u8 {
        const cols = Database.getCols(RowOfT(Target));
        return "SELECT " ++ cols ++ " FROM " ++ Target.table_name ++
            " WHERE id IN (" ++
            "SELECT " ++ Target.resource_name ++ " FROM " ++ Link.table_name ++ " WHERE " ++ Parent.resource_name ++ " = $1" ++
            ") ORDER BY id";
    }

    pub fn readRelated(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Target: type, comptime Link: type, parent_id: u32) ![]Target {
        const query = comptime Database.readRelatedQuery(Parent, Target, Link);

        const parent_id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{parent_id}, 0);
        defer gpa.free(parent_id_cstr);

        const result = try self.conn.execParams(query, &.{parent_id_cstr});
        defer result.deinit();

        const count = result.len();
        var items = try gpa.alloc(Target, count);

        const QueryType = RowOfT(Target);
        for (0..count) |row| {
            const target_row = try Database.rowToT(QueryType, gpa, &result, row);
            items[row] = try self.hydrate(Target, gpa, target_row);
        }

        return items;
    }

    /// A sub-collection is the only place its values can be read, so the order
    /// they come back in is part of what a client sees. Without ORDER BY
    /// Postgres may return the rows in any order it likes, and an UPDATE can
    /// move a row, so a sheet would come back reordered after being saved.
    fn readSubResourceQuery(comptime Parent: type, comptime Child: type) [:0]const u8 {
        const cols = Database.getCols(RowOfT(Child));

        const order_by = if (@hasDecl(Child, "order_by")) Child.order_by else Child.Body.key_name;
        return "SELECT " ++ cols ++ " FROM " ++ Child.table_name ++
            " WHERE " ++ Parent.resource_name ++ " = $1" ++
            " ORDER BY " ++ order_by;
    }

    pub fn readSubResource(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Child: type, parent_id: u32) ![]Child {
        const QueryType = RowOfT(Child);

        const query = comptime Database.readSubResourceQuery(Parent, Child);

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

    /// The update binds Body's fields from $2 upwards, and getParams renders
    /// them in declaration order. They are often all integers, so a reordered
    /// struct would swap the key with a column without any type error: pin the
    /// layout here. The key comes first, and every field after it names a
    /// column the update writes.
    fn requireBodyLayout(comptime Body: type) void {
        const fields = @typeInfo(Body).@"struct".fields;
        const ordered = fields.len >= 2 and std.mem.eql(u8, fields[0].name, Body.key_name);

        if (!ordered) {
            @compileError(@typeName(Body) ++ " must declare `" ++ Body.key_name ++
                "` then the columns it writes: updateSubResourceQuery binds them from $2 in that order.");
        }
    }

    fn updateSubResourceQuery(comptime Parent: type, comptime Child: type, comptime Body: type) [:0]const u8 {
        requireBodyLayout(Body);

        comptime var assignments: []const u8 = "";
        inline for (@typeInfo(Body).@"struct".fields[1..], 0..) |field, i| {
            if (i != 0) assignments = assignments ++ ", ";
            assignments = assignments ++ field.name ++ " = $" ++ std.fmt.comptimePrint("{d}", .{i + 3});
        }

        return "UPDATE " ++ Child.table_name ++ " SET " ++ assignments ++
            " WHERE " ++ Parent.resource_name ++ " = $1 AND " ++ Body.key_name ++ " = $2";
    }

    /// Writes rows of a sub-collection and nothing more. A model settling the
    /// consequences of a write is already inside a transaction, so it uses this
    /// rather than updateSubResource, which opens one.
    pub fn updateSubRows(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Child: type, comptime Body: type, parent_id: u32, bodies: []const Body) !void {
        const query = comptime Database.updateSubResourceQuery(Parent, Child, Body);

        const parent_id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{parent_id}, 0);
        defer gpa.free(parent_id_cstr);

        for (bodies) |body| {
            const params = try Database.getParams(gpa, Body, body);
            defer {
                for (params) |param| {
                    if (param) |present| gpa.free(std.mem.span(present));
                }
            }

            // $1 is the parent id, then Body's fields in declaration order.
            var all_params: [1 + params.len]?[*:0]const u8 = undefined;
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
    }

    /// Refines one existing relation row through its parent and target ids. The
    /// caller is already responsible for the transaction and any model hooks;
    /// this only changes the link payload.
    fn updateRelationQuery(comptime Parent: type, comptime Target: type, comptime Link: type) [:0]const u8 {
        const Update = Link.RelationUpdate;
        const fields = @typeInfo(Update).@"struct".fields;
        if (fields.len == 0) @compileError(@typeName(Link) ++ ".RelationUpdate must name a payload column");

        comptime var assignments: []const u8 = "";
        inline for (fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, Parent.resource_name) or std.mem.eql(u8, field.name, Target.resource_name)) {
                @compileError(@typeName(Link) ++ ".RelationUpdate cannot update relation keys");
            }
            if (field.is_comptime) @compileError(@typeName(Link) ++ ".RelationUpdate fields must be runtime values");

            if (i != 0) assignments = assignments ++ ", ";
            assignments = assignments ++ field.name ++ " = $" ++ std.fmt.comptimePrint("{d}", .{i + 3});
        }

        return "UPDATE " ++ Link.table_name ++ " SET " ++ assignments ++
            " WHERE " ++ Parent.resource_name ++ " = $1 AND " ++ Target.resource_name ++ " = $2";
    }

    /// Updates the payload on one relation row identified by its parent and
    /// target. The pair must already exist and uniquely identify the row.
    pub fn updateRelation(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Target: type, comptime Link: type, parent_id: u32, target_id: u32, values: Link.RelationUpdate) !void {
        const query = comptime Database.updateRelationQuery(Parent, Target, Link);
        const parent_id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{parent_id}, 0);
        defer gpa.free(parent_id_cstr);
        const target_id_cstr = try std.fmt.allocPrintSentinel(gpa, "{d}", .{target_id}, 0);
        defer gpa.free(target_id_cstr);

        const params = try Database.getParams(gpa, Link.RelationUpdate, values);
        defer for (params) |param| {
            if (param) |present| gpa.free(std.mem.span(present));
        };

        var all_params: [2 + params.len]?[*:0]const u8 = undefined;
        all_params[0] = parent_id_cstr;
        all_params[1] = target_id_cstr;
        for (params, 0..) |param, i| all_params[i + 2] = param;

        const result = try self.conn.execParams(query, &all_params);
        defer result.deinit();
        if (try result.affectedRows() != 1) return error.ItemNotFound;
    }

    pub fn updateSubResource(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Child: type, parent_id: u32, bodies: []const Child.Body) !void {
        try self.conn.beginTransaction();
        errdefer self.conn.rollbackTransaction() catch {
            std.log.err("Failed to rollback transaction: {s}", .{self.conn.errorMessage()});
        };

        // Whether this collection accepts a direct write can depend on the
        // parent's state. A child that says so is asked here, inside the
        // transaction, so it reads the same rows the writes below change.
        if (@hasDecl(Child, "checkWritable")) try Child.checkWritable(self, gpa, parent_id);

        try self.updateSubRows(gpa, Parent, Child, Child.Body, parent_id, bodies);

        // Other values on the sheet can follow from these rows. A child with
        // such consequences settles them here, in the same transaction, so the
        // whole sheet moves at once.
        if (@hasDecl(Child, "afterUpdate")) try Child.afterUpdate(self, gpa, parent_id);

        try self.conn.commitTransaction();
    }

    /// A metadata-defined nested action has its own atomic database operation,
    /// unlike a row collection whose generic update is above. The handler
    /// reaches both through the same sub-resource definition.
    pub fn applySubAction(self: *const Database, gpa: Allocator, comptime Parent: type, comptime Action: type, parent_id: u32, body: Action.Body) !void {
        _ = Parent;
        comptime {
            if (!@hasDecl(Action, "apply")) {
                @compileError(@typeName(Action) ++ " must define apply for a nested action.");
            }
        }

        // An action decides against state it reads and then writes several
        // rows. The transaction is here rather than in the action so that every
        // action is atomic without each one remembering to be.
        try self.conn.beginTransaction();
        errdefer self.conn.rollbackTransaction() catch {
            std.log.err("Failed to rollback transaction: {s}", .{self.conn.errorMessage()});
        };

        try Action.apply(self, gpa, parent_id, body);
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

    /// Build the SELECT query dynamically based on the fields of the struct T.
    fn readAllQuery(comptime T: type) [:0]const u8 {
        // Composite keys supply their own ordering; other collections use id.
        if (!@hasDecl(T, "order_by")) requireIdColumn(T);
        const cols = Database.getCols(RowOfT(T));
        const order_by = if (@hasDecl(T, "order_by")) T.order_by else "id";
        return "SELECT " ++ cols ++ " FROM " ++ T.table_name ++ " ORDER BY " ++ order_by;
    }

    /// Every row of a table. Reading a subset that belongs to a parent is
    /// readSubResource's job, which is why there is no filter here.
    pub fn readAllAlloc(self: *const Database, gpa: Allocator, comptime T: type) ![]T {
        const QueryType = RowOfT(T);

        const query = comptime readAllQuery(T);

        const result = try self.conn.exec(query);
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
            const value = if (result.isNull(row, col_index)) null else std.mem.span(result.getValue(row, col_index));
            @field(ret, field.name) = try parseValue(field.type, gpa, value);
        }
        return ret;
    }

    /// A model declares Row and fromRow when its stored and returned shapes differ.
    /// For example, fromRow can expand foreign-key IDs into nested records.
    /// Without Row, the database reads the model directly, so its fields must
    /// match the stored columns.
    ///
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

    /// SQL NULL becomes a Zig optional; an empty string remains a value.
    fn parseValue(comptime T: type, gpa: Allocator, value: ?[]const u8) !T {
        if (@typeInfo(T) == .optional) {
            return if (value) |present| try parseValue(@typeInfo(T).optional.child, gpa, present) else null;
        }
        const present = value orelse return error.UnexpectedNull;
        return switch (@typeInfo(T)) {
            .int => try std.fmt.parseInt(T, present, 10),
            .float => try std.fmt.parseFloat(T, present),
            .bool => if (std.mem.eql(u8, present, "t")) true else if (std.mem.eql(u8, present, "f")) false else error.InvalidCharacter,
            .pointer => if (T == []const u8 or T == []u8)
                try gpa.dupe(u8, present)
            else
                @compileError("Unsupported pointer type: " ++ @typeName(T)),
            else => @compileError("Unsupported field type: " ++ @typeName(T)),
        };
    }

    /// libpq represents a SQL NULL parameter with a null pointer.
    fn formatParam(gpa: Allocator, value: anytype) !?[*:0]const u8 {
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .optional => if (value) |present| try formatParam(gpa, present) else null,
            .bool => try gpa.dupeZ(u8, if (value) "true" else "false"),
            .int => try std.fmt.allocPrintSentinel(gpa, "{d}", .{value}, 0),
            .float => try std.fmt.allocPrintSentinel(gpa, "{}", .{value}, 0),
            .pointer => if (T == []const u8 or T == []u8)
                try gpa.dupeZ(u8, value)
            else
                @compileError("Unsupported pointer type: " ++ @typeName(T)),
            else => @compileError("Unsupported field type: " ++ @typeName(T)),
        };
    }

    fn getParams(gpa: Allocator, comptime T: type, item: T) ![@typeInfo(T).@"struct".fields.len]?[*:0]const u8 {
        const fields = @typeInfo(T).@"struct".fields;
        var params: [fields.len]?[*:0]const u8 = @splat(null);
        errdefer for (params) |param| {
            if (param) |present| gpa.free(std.mem.span(present));
        };
        inline for (fields, 0..) |field, i| {
            params[i] = try formatParam(gpa, @field(item, field.name));
        }
        return params;
    }

    fn getParamsWithId(gpa: Allocator, comptime T: type, item: T, id: u32) ![@typeInfo(T).@"struct".fields.len + 1]?[*:0]const u8 {
        const params = try getParams(gpa, T, item);
        errdefer for (params) |param| {
            if (param) |present| gpa.free(std.mem.span(present));
        };
        return params ++ [_]?[*:0]const u8{try formatParam(gpa, id)};
    }

    pub fn insertItem(self: *const Database, gpa: Allocator, comptime T: type, item: T.Create) !u32 {
        comptime requireIdColumn(T);

        const cols = comptime Database.getCols(T.Create);
        const placeholders = comptime Database.getPlaceholders(T.Create);

        const query = "INSERT INTO " ++ T.table_name ++ " (" ++ cols ++ ") VALUES (" ++ placeholders ++ ") RETURNING id";

        const params = try Database.getParams(gpa, T.Create, item);

        // A model whose creation takes more than one row says so with
        // afterInsert. Both statements share this transaction, so a hook that
        // fails leaves no half-built record behind.
        try self.conn.beginTransaction();
        errdefer self.conn.rollbackTransaction() catch {
            std.log.err("Failed to rollback transaction: {s}", .{self.conn.errorMessage()});
        };

        const id = id: {
            const result = try self.conn.execParams(query, &params);
            defer result.deinit();

            if (result.len() != 1) {
                return error.UnexpectedResult;
            }
            const id_cstr = result.getValue(0, 0);
            const id_str = std.mem.span(id_cstr);
            break :id try std.fmt.parseInt(u32, id_str, 10);
        };

        if (@hasDecl(T, "afterInsert")) try T.afterInsert(self, gpa, id, item);

        try self.conn.commitTransaction();
        return id;
    }

    pub fn getSetClauses(comptime T: type) []const u8 {
        // Long update bodies repeat comptimePrint once per field. Keep this
        // generic query builder usable for a normal record such as Item.
        @setEvalBranchQuota(10_000);
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

    /// An anonymous literal leaves an untyped field comptime, and a
    /// comptime_int has no width to send as a parameter. The call site fixes
    /// it by naming the type of the value.
    fn requireRuntimeFields(comptime T: type) void {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (field.is_comptime) {
                @compileError(@typeName(T) ++ "." ++ field.name ++ " is comptime, so it cannot be sent" ++
                    " as a query parameter. Give the value a runtime type, such as @as(u32, 1).");
            }
        }
    }

    /// Writes the fields of `values` to one row addressed by id. The write side
    /// of readProjection: a model that changes part of a record names the
    /// columns it sets and leaves the statement to the query layer.
    pub fn updateColumns(self: *const Database, gpa: Allocator, comptime T: type, id: u32, values: anytype) !void {
        comptime requireIdColumn(T);
        comptime requireRuntimeFields(@TypeOf(values));

        const set_clauses = comptime Database.getSetClauses(@TypeOf(values));
        const query = "UPDATE " ++ T.table_name ++ " SET " ++ set_clauses;

        const params = try Database.getParamsWithId(gpa, @TypeOf(values), values, id);

        const result = try self.conn.execParams(query, &params);
        defer result.deinit();

        if (try result.affectedRows() != 1) {
            return error.ItemNotFound;
        }
    }

    /// A whole-row update is every column the model's Update body carries.
    ///
    /// A model that has to prepare the row first declares beforeUpdate. It runs
    /// inside this transaction and ahead of the statement, so the update and
    /// anything the database does behind it read the prepared row. The insert
    /// hook runs the other way round, because a row has no id until it exists.
    pub fn updateItem(self: *const Database, gpa: Allocator, comptime T: type, id: u32, item: T.Update) !void {
        try self.conn.beginTransaction();
        errdefer self.conn.rollbackTransaction() catch {
            std.log.err("Failed to rollback transaction: {s}", .{self.conn.errorMessage()});
        };

        if (@hasDecl(T, "beforeUpdate")) try T.beforeUpdate(self, gpa, id, item);

        try self.updateColumns(gpa, T, id, item);
        try self.conn.commitTransaction();
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

const all_models = .{ Character, Item, Kin, Skill };

test "getCols lists the fields in declaration order" {
    try std.testing.expectEqualStrings("id, creation_status, name, level, kin, profession, specialization, age, attribute_points, trained_skill_points, creation_complete, movement, damage_bonuses, attributes, skills", comptime Database.getCols(Character));
    try std.testing.expectEqualStrings("id, name, icon, movement", comptime Database.getCols(Kin.Row));
    try std.testing.expectEqualStrings("id, name, icon, kind, attribute, description", comptime Database.getCols(Skill));
    try std.testing.expectEqualStrings("id, name, icon, description", comptime Database.getCols(Profession.Row));
    try std.testing.expectEqualStrings("id, name, icon, kind, cost, supply, weight, effect, description", comptime Database.getCols(Item));
    // Insert columns come from the Create type, which must never carry `id`:
    // getPlaceholders and getParams both assume every field is insertable.
    try std.testing.expectEqualStrings("name, level, kin, profession, age", comptime Database.getCols(Character.Create));
    try std.testing.expectEqualStrings("name, icon, movement", comptime Database.getCols(Kin.Create));
    try std.testing.expectEqualStrings("name, icon, kind, attribute, description", comptime Database.getCols(Skill.Create));
    try std.testing.expectEqualStrings("name, icon, kind, cost, supply, weight, effect, description", comptime Database.getCols(Item.Create));
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
    try std.testing.expectEqualStrings("$1, $2, $3, $4, $5", comptime Database.getPlaceholders(Character.Create));
    try std.testing.expectEqualStrings("$1, $2, $3", comptime Database.getPlaceholders(Kin.Create));
    try std.testing.expectEqualStrings("$1, $2, $3, $4, $5", comptime Database.getPlaceholders(Skill.Create));
    try std.testing.expectEqualStrings("$1, $2, $3, $4, $5, $6, $7, $8", comptime Database.getPlaceholders(Item.Create));
}

test "getSetClauses derives the id placeholder from the field count" {
    // Regression guard: a hardcoded `WHERE id = $3` once broke PUT /kins/<id>,
    // because Kin.Update has one body field and its id parameter is $2.
    try std.testing.expectEqualStrings(
        "name = $1, level = $2, kin = $3, profession = $4, age = $5 WHERE id = $6",
        comptime Database.getSetClauses(Character.Update),
    );
    try std.testing.expectEqualStrings(
        "name = $1, icon = $2, movement = $3 WHERE id = $4",
        comptime Database.getSetClauses(Kin.Update),
    );
    try std.testing.expectEqualStrings(
        "name = $1, icon = $2, kind = $3, attribute = $4, description = $5 WHERE id = $6",
        comptime Database.getSetClauses(Skill.Update),
    );
    try std.testing.expectEqualStrings(
        "name = $1, icon = $2, kind = $3, cost = $4, supply = $5, weight = $6, effect = $7, description = $8 WHERE id = $9",
        comptime Database.getSetClauses(Item.Update),
    );
}

test "readSubResourceQuery orders the rows it returns" {
    // These are now the only URL a sheet's values can be read from, so an
    // unordered result would let a page render its rows differently on every
    // load, and differently again after a save.
    try std.testing.expectEqualStrings(
        "SELECT character, attribute, base, spent, modifier, value FROM character_attributes WHERE character = $1 ORDER BY attribute",
        comptime Database.readSubResourceQuery(Character, CharacterAttribute),
    );
    try std.testing.expectEqualStrings(
        "SELECT character, skill, value, trained FROM character_skills WHERE character = $1 ORDER BY skill",
        comptime Database.readSubResourceQuery(Character, CharacterSkill),
    );
}

test "readAllQuery orders a collection by the one column an edit cannot move" {
    // Without ORDER BY Postgres returns heap order, and an UPDATE writes a new
    // tuple at the end of the heap: editing a row dropped it to the bottom of
    // its roster and left it there. Ordering by id is stable because no edit
    // can change it; name is unique too, and is exactly what an edit changes.
    try std.testing.expectEqualStrings(
        "SELECT id, name FROM icons ORDER BY id",
        comptime Database.readAllQuery(Icon),
    );
    try std.testing.expectEqualStrings(
        "SELECT id, name, icon, movement FROM kins ORDER BY id",
        comptime Database.readAllQuery(Kin),
    );
    // Read whole on every character read, to derive movement.
    try std.testing.expectEqualStrings(
        "SELECT id, attribute, min_value, max_value, modifier FROM movement_modifiers ORDER BY id",
        comptime Database.readAllQuery(MovementModifier),
    );
    // The roster reads summaries, so this is the query behind /characters.
    try std.testing.expectEqualStrings(
        "SELECT id, creation_status, name, level, kin, profession, specialization, age, attribute_points, trained_skill_points FROM characters ORDER BY id",
        comptime Database.readAllQuery(Character.Summary),
    );
}

test "readAllQuery supports a table with a composite key" {
    try std.testing.expectEqualStrings(
        "SELECT attribute, min_value, die_sides FROM damage_bonuses ORDER BY attribute, min_value",
        comptime Database.readAllQuery(model.DamageBonus),
    );
}

test "updateSubResourceQuery keys the update on both halves of the composite key" {
    // These tables have no id, so the WHERE clause names the whole primary key.
    // $1 is the parent and never changes across a batch, which is why it comes
    // first even though it appears last in the text.
    try std.testing.expectEqualStrings(
        "UPDATE character_attributes SET spent = $3 WHERE character = $1 AND attribute = $2",
        comptime Database.updateSubResourceQuery(Character, CharacterAttribute, CharacterAttribute.Body),
    );
    try std.testing.expectEqualStrings(
        "UPDATE character_skills SET value = $3 WHERE character = $1 AND skill = $2",
        comptime Database.updateSubResourceQuery(Character, CharacterSkill, CharacterSkill.Body),
    );

    // A body may name more than one column, which creation needs to mark a
    // skill trained at the same time as it writes the value.
    const TwoColumns = struct {
        pub const key_name: []const u8 = "skill";
        skill: u32,
        value: u32,
        trained: bool,
    };
    try std.testing.expectEqualStrings(
        "UPDATE character_skills SET value = $3, trained = $4 WHERE character = $1 AND skill = $2",
        comptime Database.updateSubResourceQuery(Character, CharacterSkill, TwoColumns),
    );
}

test "updateRelationQuery updates only payload columns through both relation keys" {
    try std.testing.expectEqualStrings(
        "UPDATE character_skills SET value = $3, trained = $4 WHERE character = $1 AND skill = $2",
        comptime Database.updateRelationQuery(Character, Skill, CharacterSkill),
    );
}

test "a sub-resource body renders its params in the order the update binds them" {
    const gpa = std.testing.allocator;

    // The seam between updateSubResourceQuery and getParams: $2 is the key and
    // $3 is the value, and nothing but declaration order makes that true.
    const params = try Database.getParams(gpa, CharacterAttribute.Body, .{ .attribute = 5, .spent = 9 });
    defer {
        for (params) |param| {
            if (param) |present| gpa.free(std.mem.span(present));
        }
    }

    try std.testing.expectEqualStrings("5", std.mem.span(params[0].?));
    try std.testing.expectEqualStrings("9", std.mem.span(params[1].?));
}

test "a model without a Row type queries its own fields" {
    // Character declares Row because its `kin` column is an id on the wire but a
    // nested Kin in the struct. Skill has no such split, so RowOfT must fall
    // back to Skill itself rather than requiring every model to declare a Row.
    try std.testing.expectEqual(Skill.Row, Database.RowOfT(Skill));
    try std.testing.expectEqual(Kin.Row, Database.RowOfT(Kin));
    try std.testing.expectEqual(Icon, Database.RowOfT(Icon));
    try std.testing.expectEqual(Item.Row, Database.RowOfT(Item));
    try std.testing.expectEqual(Character.Row, Database.RowOfT(Character));
}

test "nullable SQL values preserve null, zero, and empty strings" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?u32, null), try Database.parseValue(?u32, gpa, null));
    try std.testing.expectEqual(@as(?u32, 0), try Database.parseValue(?u32, gpa, "0"));
    try std.testing.expectEqual(@as(?u32, 2), try Database.parseValue(?u32, gpa, "2"));
    try std.testing.expectError(error.UnexpectedNull, Database.parseValue(u32, gpa, null));
    try std.testing.expectError(error.InvalidCharacter, Database.parseValue(?u32, gpa, ""));
    const empty = try Database.parseValue(?[]const u8, gpa, "");
    defer gpa.free(empty.?);
    try std.testing.expectEqualStrings("", empty.?);
}

test "floating SQL values round-trip through the generic codec" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(f64, 0.25), try Database.parseValue(f64, gpa, "0.25"));
    try std.testing.expectEqual(@as(?f64, null), try Database.parseValue(?f64, gpa, null));

    const param = try Database.formatParam(gpa, @as(f64, 0.25));
    defer gpa.free(std.mem.span(param.?));
    try std.testing.expectEqualStrings("0.25", std.mem.span(param.?));
}

test "nullable parameters bind null pointers and retain the update id" {
    const gpa = std.testing.allocator;
    const Body = struct { attribute: ?u32 };
    const absent = try Database.getParamsWithId(gpa, Body, .{ .attribute = null }, 9);
    defer gpa.free(std.mem.span(absent[1].?));
    try std.testing.expect(absent[0] == null);
    try std.testing.expectEqualStrings("9", std.mem.span(absent[1].?));

    const present = try Database.getParams(gpa, Body, .{ .attribute = 2 });
    defer gpa.free(std.mem.span(present[0].?));
    try std.testing.expectEqualStrings("2", std.mem.span(present[0].?));
}

test "getParams renders fields as C strings in declaration order" {
    const gpa = std.testing.allocator;

    const params = try Database.getParams(gpa, Character.Create, .{
        .name = "Grog",
        .level = 3,
        .kin = 1,
        .profession = 1,
        .age = 1,
    });
    defer {
        for (params) |param| {
            if (param) |present| gpa.free(std.mem.span(present));
        }
    }

    try std.testing.expectEqualStrings("Grog", std.mem.span(params[0].?));
    try std.testing.expectEqualStrings("3", std.mem.span(params[1].?));
    try std.testing.expectEqualStrings("1", std.mem.span(params[2].?));
    try std.testing.expectEqualStrings("1", std.mem.span(params[3].?));
}

test "getParamsWithId appends the id as the final parameter" {
    const gpa = std.testing.allocator;

    // The id position must match the placeholder getSetClauses generates.
    const params = try Database.getParamsWithId(gpa, Kin.Update, .{ .name = "Elf", .icon = 1, .movement = 10 }, 9);
    defer {
        for (params) |param| {
            if (param) |present| gpa.free(std.mem.span(present));
        }
    }

    try std.testing.expectEqualStrings("Elf", std.mem.span(params[0].?));
    try std.testing.expectEqualStrings("1", std.mem.span(params[1].?));
}
