// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

//! Turns the JSON in `src/data/` into the seed `.sql` files in `db/`.
//!
//! Each table below is described once, by a struct: where its JSON lives, which
//! file to write, and what a row looks like. Everything else -- reading the
//! JSON, quoting the values, resolving a name into the id it refers to, and
//! assembling the statement -- is the same for every table and written once.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Generate the insertion SQL files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    // A build tool that runs once and exits: everything it reads and builds
    // goes in here and is released in one go.
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const gpa = arena.allocator();

    try generate(init.io, gpa, Configs);
    try generate(init.io, gpa, Icons);
    try generate(init.io, gpa, Kins);
    try generate(init.io, gpa, Attributes);
    try generate(init.io, gpa, SkillKinds);
    try generate(init.io, gpa, Skills);
    try generate(init.io, gpa, Ages);
    try generate(init.io, gpa, AgeAttributes);
    try generate(init.io, gpa, MovementModifiers);
}

// The tables. Each names its JSON source, its output file, and the single
// property of that JSON holding the list to insert. A row of plain strings is
// a list of names; a row of struct fields is one column per field, in order.

const Configs = struct {
    const table_name = "configs";
    const json_path = "src/data/configs.json";
    const out_path = "db/0001-configs.sql";

    const Row = struct {
        name: []const u8,
        value: []const u8,
    };

    configs: []const Row,
};

/// A JSON Schema enumeration: a list of names and nothing else.
const Icons = struct {
    const table_name = "icons";
    const json_path = "src/data/icon-names.schema.json";
    const out_path = "db/0011-icons.sql";

    @"enum": []const []const u8,
};

const SkillKinds = struct {
    const table_name = "skill_kinds";
    const json_path = "src/data/skill-kinds.schema.json";
    const out_path = "db/0041-skill-kinds.sql";

    @"enum": []const []const u8,
};

const Kins = struct {
    const table_name = "kins";
    const json_path = "src/data/kins.json";
    const out_path = "db/0021-kins.sql";

    /// The JSON also carries a description, which the table has no column for.
    /// Unknown properties are ignored, so leaving it out here is enough.
    const Row = struct {
        /// A field named here holds the *name* of a row in another table; the
        /// generated SQL looks up its id.
        const lookups = .{ .icon = "icons" };

        name: []const u8,
        icon: []const u8,
        movement: []const u8,
    };

    kins: []const Row,
};

const Attributes = struct {
    const table_name = "attributes";
    const json_path = "src/data/attributes.json";
    const out_path = "db/0031-attributes.sql";

    const Row = struct {
        const lookups = .{ .icon = "icons" };

        name: []const u8,
        icon: []const u8,
        short: []const u8,
        description: []const u8,
    };

    attributes: []const Row,
};

const Skills = struct {
    const table_name = "skills";
    const json_path = "src/data/skills.json";
    const out_path = "db/0042-skills.sql";

    const Row = struct {
        const lookups = .{ .icon = "icons", .kind = "skill_kinds" };

        name: []const u8,
        icon: []const u8,
        kind: []const u8,
        description: []const u8,
    };

    skills: []const Row,
};

const MovementModifiers = struct {
    const table_name = "movement_modifiers";
    const json_path = "src/data/movement-modifiers.json";
    const out_path = "db/0033-movement-modifiers.sql";

    const Row = struct {
        const lookups = .{ .attribute = "attributes" };

        attribute: []const u8,
        min_value: []const u8,
        max_value: []const u8,
        modifier: []const u8,
    };

    movement_modifiers: []const Row,
};

/// A join table: both columns hold ids, both come from names in the JSON.
const AgeAttributes = struct {
    const table_name = "age_attributes";
    const json_path = "src/data/age-attributes.json";
    const out_path = "db/0053-age-attributes.sql";

    const Row = struct {
        const lookups = .{ .age = "ages", .attribute = "attributes" };

        age: []const u8,
        attribute: []const u8,
        modifier: []const u8,
    };

    age_attributes: []const Row,
};

const Ages = struct {
    const table_name = "ages";
    const json_path = "src/data/ages.json";
    const out_path = "db/0051-ages.sql";

    const Row = struct {
        const lookups = .{ .icon = "icons" };

        name: []const u8,
        icon: []const u8,
    };

    ages: []const Row,
};

/// Reads one table's JSON and writes its INSERT statement.
fn generate(io: Io, gpa: Allocator, comptime Table: type) !void {
    const table = try readJson(io, gpa, Table);

    const rows = @field(table, listField(Table).name);
    if (rows.len == 0) {
        std.log.err("{s} lists no rows", .{Table.json_path});
        return error.NoRows;
    }

    const Row = @typeInfo(@TypeOf(rows)).pointer.child;

    var sql = std.ArrayList(u8).empty;

    try sql.appendSlice(gpa, "INSERT INTO " ++ Table.table_name ++
        " (" ++ comptime columnsOf(Row) ++ ") VALUES\n");

    for (rows, 0..) |row, i| {
        if (i > 0) try sql.appendSlice(gpa, ",\n");

        appendRow(gpa, &sql, Row, row) catch |err| {
            // Reported here because this is the layer that knows which file the
            // offending value came from.
            std.log.err("{s}: row {d}: {}", .{ Table.json_path, i, err });
            return err;
        };
    }
    try sql.appendSlice(gpa, ";\n");

    try Io.Dir.cwd().writeFile(io, .{ .data = sql.items, .sub_path = Table.out_path, .flags = .{} });

    std.log.info("{s}: {d} rows", .{ Table.out_path, rows.len });
}

/// The one property of a table's JSON that holds its list. Declaring a second
/// field would make "which one is the list" a guess, so require exactly one.
fn listField(comptime Table: type) std.builtin.Type.StructField {
    const fields = @typeInfo(Table).@"struct".fields;
    if (fields.len != 1) {
        @compileError(@typeName(Table) ++ " must declare exactly one field: the JSON property holding its rows.");
    }
    return fields[0];
}

/// The column list, in the order the values are written. A row that is just a
/// string is a name; anything else contributes one column per field.
fn columnsOf(comptime Row: type) []const u8 {
    if (Row == []const u8) return "name";

    comptime var columns: []const u8 = "";
    inline for (@typeInfo(Row).@"struct".fields, 0..) |field, i| {
        if (i > 0) columns = columns ++ ", ";
        columns = columns ++ field.name;
    }
    return columns;
}

/// The table a field's value names, or null when the value is stored as it is.
fn lookupOf(comptime Row: type, comptime field_name: []const u8) ?[]const u8 {
    if (Row == []const u8) return null;
    if (!@hasDecl(Row, "lookups")) return null;
    if (!@hasField(@TypeOf(Row.lookups), field_name)) return null;

    return @field(Row.lookups, field_name);
}

fn appendRow(gpa: Allocator, sql: *std.ArrayList(u8), comptime Row: type, row: Row) !void {
    try sql.appendSlice(gpa, "    (");

    if (Row == []const u8) {
        try appendValue(gpa, sql, null, row);
    } else {
        inline for (@typeInfo(Row).@"struct".fields, 0..) |field, i| {
            if (i > 0) try sql.appendSlice(gpa, ", ");
            try appendValue(gpa, sql, comptime lookupOf(Row, field.name), @field(row, field.name));
        }
    }

    try sql.appendSlice(gpa, ")");
}

fn appendValue(
    gpa: Allocator,
    sql: *std.ArrayList(u8),
    comptime lookup_table: ?[]const u8,
    value: []const u8,
) !void {
    if (lookup_table) |referenced| {
        try sql.appendSlice(gpa, "(SELECT id FROM " ++ referenced ++ " WHERE name = ");
        try appendQuoted(gpa, sql, value);
        try sql.appendSlice(gpa, " LIMIT 1)");
    } else {
        try appendQuoted(gpa, sql, value);
    }
}

/// Postgres reads everything between two matching `$tag$` markers literally, so
/// a value carrying an apostrophe needs no escaping and cannot end its own
/// literal. That matters here: these files are generated from prose written by
/// a person, and "a dwarf's beard" would otherwise close the string early and
/// produce SQL that fails to apply -- or worse, applies as something else.
const quote = "$val$";

fn appendQuoted(gpa: Allocator, sql: *std.ArrayList(u8), value: []const u8) !void {
    // The only text that could still end the literal early is the marker
    // itself. No data uses it, and picking a different marker on the fly would
    // be a silent fix for something worth seeing.
    if (std.mem.find(u8, value, quote) != null) return error.ValueContainsQuoteMarker;

    try sql.appendSlice(gpa, quote);
    try sql.appendSlice(gpa, value);
    try sql.appendSlice(gpa, quote);
}

fn readJson(io: Io, gpa: Allocator, comptime Table: type) !Table {
    const file = try Io.Dir.cwd().openFile(io, Table.json_path, .{ .mode = .read_only });
    defer file.close(io);

    var staging_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &staging_buffer);

    var json_reader = std.json.Reader.init(gpa, &file_reader.interface);
    defer json_reader.deinit();

    return std.json.parseFromTokenSourceLeaky(
        Table,
        gpa,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.log.err("{s}: {}", .{ Table.json_path, err });
        return error.MalformedMetadata;
    };
}

const testing = std.testing;

/// Every table this tool writes, for the checks below.
const all_tables = .{ Configs, Ages, AgeAttributes, MovementModifiers, Icons, SkillKinds, Kins, Attributes, Skills };

test "every table names exactly one JSON property to read its rows from" {
    inline for (all_tables) |Table| {
        const field = comptime listField(Table);

        // The property holds a list, and its elements are either names or rows.
        const Row = @typeInfo(field.type).pointer.child;
        try testing.expect(Row == []const u8 or @typeInfo(Row) == .@"struct");

        try testing.expect(Table.table_name.len > 0);
        try testing.expect(std.mem.endsWith(u8, Table.out_path, ".sql"));
        try testing.expect(std.mem.endsWith(u8, Table.json_path, ".json"));
    }
}

test "columns are the row's fields, in order" {
    try testing.expectEqualStrings("name", comptime columnsOf([]const u8));
    try testing.expectEqualStrings("name, icon, movement", comptime columnsOf(Kins.Row));
    try testing.expectEqualStrings("attribute, min_value, max_value, modifier", comptime columnsOf(MovementModifiers.Row));
    try testing.expectEqualStrings("age, attribute, modifier", comptime columnsOf(AgeAttributes.Row));
    try testing.expectEqualStrings("name, icon, short, description", comptime columnsOf(Attributes.Row));
    try testing.expectEqualStrings("name, icon, kind, description", comptime columnsOf(Skills.Row));
}

test "a lookup field names the table its value refers to" {
    // These are the columns holding an id in the database but a name in the
    // JSON, which is what makes the generated SELECT necessary.
    try testing.expectEqualStrings("icons", comptime lookupOf(Kins.Row, "icon").?);
    try testing.expectEqualStrings("skill_kinds", comptime lookupOf(Skills.Row, "kind").?);
    // Both halves of the join table are looked up; the modifier is stored as written.
    try testing.expectEqualStrings("ages", comptime lookupOf(AgeAttributes.Row, "age").?);
    try testing.expectEqualStrings("attributes", comptime lookupOf(AgeAttributes.Row, "attribute").?);
    try testing.expect(comptime lookupOf(AgeAttributes.Row, "modifier") == null);
    try testing.expect(comptime lookupOf(Skills.Row, "name") == null);
    try testing.expect(comptime lookupOf([]const u8, "name") == null);
}

/// Whether some table in this file fills the named table.
fn fills(comptime table_name: []const u8) bool {
    inline for (all_tables) |Table| {
        if (std.mem.eql(u8, Table.table_name, table_name)) return true;
    }
    return false;
}

test "every lookup points at a table this tool fills" {
    // A lookup naming a table nobody writes would generate a SELECT that finds
    // nothing, and the insert would quietly store a null id.
    inline for (all_tables) |Table| {
        const Row = @typeInfo(listField(Table).type).pointer.child;

        if (Row != []const u8 and @hasDecl(Row, "lookups")) {
            inline for (@typeInfo(@TypeOf(Row.lookups)).@"struct".fields) |lookup| {
                try testing.expect(comptime fills(@field(Row.lookups, lookup.name)));
            }
        }
    }
}

test "values are dollar quoted, so an apostrophe cannot end one early" {
    const gpa = testing.allocator;

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(gpa);

    // The case that produced broken SQL when names were wrapped in apostrophes.
    try appendRow(gpa, &sql, Kins.Row, .{ .name = "Dwarf's kin", .icon = "beard", .movement = "8" });

    try testing.expectEqualStrings(
        "    ($val$Dwarf's kin$val$, (SELECT id FROM icons WHERE name = $val$beard$val$ LIMIT 1), $val$8$val$)",
        sql.items,
    );
}

test "a name is written as a single column" {
    const gpa = testing.allocator;

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(gpa);

    try appendRow(gpa, &sql, []const u8, "abacus");
    try testing.expectEqualStrings("    ($val$abacus$val$)", sql.items);
}

test "a value carrying the quoting marker is refused, not mangled" {
    const gpa = testing.allocator;

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(gpa);

    try testing.expectError(
        error.ValueContainsQuoteMarker,
        appendQuoted(gpa, &sql, "ends the literal " ++ quote ++ " early"),
    );
}
