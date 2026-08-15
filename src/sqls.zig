// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

/// Generate insertion sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    try gen_enum(init, "src/data/icon-names.schema.json", IconsSchema, "db/0011-icons.sql");
    try gen_attributes(init);
    try gen_kin(init);

    try gen_enum(init, "src/data/skill-kinds.schema.json", SkillKind, "db/0041-skill-kinds.sql");
    try gen_skills(init);
}

fn gen_enum(
    init: std.process.Init,
    sub_path: []const u8, // "src/data/icon-names.schema.json"
    comptime T: type, // IconsSchema
    out_path: []const u8, // "db/0011-icons.sql"
) !void {
    const schema_file = try std.Io.Dir.cwd().openFile(
        init.io,
        sub_path,
        .{ .mode = .read_only },
    );
    defer schema_file.close(init.io);

    var schema_staging_buffer: [1024]u8 = undefined;
    var reader = schema_file.reader(init.io, &schema_staging_buffer);

    var json_reader = std.json.Reader.init(init.gpa, &reader.interface);
    defer json_reader.deinit();

    const schema = std.json.parseFromTokenSourceLeaky(
        T,
        init.gpa,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    ) catch |e| {
        // Warn because malformed metadata can be a deeper symptom.
        std.log.warn("{}", .{e});
        return error.MalformedMetadata;
    };
    defer schema.deinit(init.gpa);

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(init.gpa);

    try sql.appendUnalignedSlice(init.gpa, "INSERT INTO ");
    try sql.appendUnalignedSlice(init.gpa, T.table_name);
    try sql.appendUnalignedSlice(init.gpa, " (name) VALUES\n");

    for (schema.@"enum") |name| {
        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", name, "'),\n" });
        defer init.gpa.free(sql_element);
        try sql.appendUnalignedSlice(init.gpa, sql_element);
    }

    sql.items[sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = sql.items, .sub_path = out_path, .flags = .{} });
}

const IconsSchema = struct {
    const table_name: []const u8 = "icons";

    title: []const u8,
    type: []const u8,
    description: []const u8,
    @"enum": []const []const u8,

    fn deinit(self: *const IconsSchema, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.type);
        gpa.free(self.description);

        for (self.@"enum") |icon_name| {
            gpa.free(icon_name);
        }
        gpa.free(self.@"enum");
    }
};

fn gen_kin(init: std.process.Init) !void {
    const kin_schema_file = try std.Io.Dir.cwd().openFile(
        init.io,
        "src/data/kins.json",
        .{ .mode = .read_only },
    );
    defer kin_schema_file.close(init.io);

    var staging_buffer: [1024]u8 = undefined;
    var reader = kin_schema_file.reader(init.io, &staging_buffer);

    var json_reader = std.json.Reader.init(init.gpa, &reader.interface);
    defer json_reader.deinit();

    const kins = std.json.parseFromTokenSourceLeaky(
        Kins,
        init.gpa,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    ) catch |e| {
        // Warn because malformed metadata can be a deeper symptom.
        std.log.warn("{}", .{e});
        return error.MalformedMetadata;
    };
    defer kins.deinit(init.gpa);

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(init.gpa);
    try sql.appendUnalignedSlice(init.gpa, "INSERT INTO kins (name, icon) VALUES\n");

    for (kins.kins) |kin| {
        const icon_id_query = try std.mem.concat(init.gpa, u8, &.{ "(SELECT id FROM icons WHERE name = '", kin.icon, "' LIMIT 1)" });
        defer init.gpa.free(icon_id_query);

        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", kin.name, "', ", icon_id_query, "),\n" });
        defer init.gpa.free(sql_element);

        try sql.appendUnalignedSlice(init.gpa, sql_element);
    }

    sql.items[sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the kins SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = sql.items, .sub_path = "db/0021-kins.sql", .flags = .{} });
}

const Kin = struct {
    name: []const u8,
    icon: []const u8,
    description: []const u8,

    fn deinit(self: *const Kin, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.icon);
        gpa.free(self.description);
    }
};

const Kins = struct {
    kins: []const Kin,

    fn deinit(self: *const Kins, gpa: std.mem.Allocator) void {
        for (self.kins) |kin| {
            kin.deinit(gpa);
        }
        gpa.free(self.kins);
    }
};

fn gen_attributes(init: std.process.Init) !void {
    const attribute_schema_file = try std.Io.Dir.cwd().openFile(
        init.io,
        "src/data/attributes.json",
        .{ .mode = .read_only },
    );
    defer attribute_schema_file.close(init.io);

    var staging_buffer: [1024]u8 = undefined;
    var reader = attribute_schema_file.reader(init.io, &staging_buffer);

    var json_reader = std.json.Reader.init(init.gpa, &reader.interface);
    defer json_reader.deinit();

    const attributes = std.json.parseFromTokenSourceLeaky(
        Attributes,
        init.gpa,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    ) catch |e| {
        // Warn because malformed metadata can be a deeper symptom.
        std.log.warn("{}", .{e});
        return error.MalformedMetadata;
    };
    defer attributes.deinit(init.gpa);

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(init.gpa);
    try sql.appendUnalignedSlice(init.gpa, "INSERT INTO attributes (name, icon, short, description) VALUES\n");

    for (attributes.attributes) |attribute| {
        const icon_id_query = try std.mem.concat(init.gpa, u8, &.{ "(SELECT id FROM icons WHERE name = '", attribute.icon, "' LIMIT 1)" });
        defer init.gpa.free(icon_id_query);

        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", attribute.name, "', ", icon_id_query, ", '", attribute.short, "', '", attribute.description, "'),\n" });
        defer init.gpa.free(sql_element);

        try sql.appendUnalignedSlice(init.gpa, sql_element);
    }

    sql.items[sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the attributes SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = sql.items, .sub_path = "db/0031-attributes.sql", .flags = .{} });
}

const Attribute = struct {
    name: []const u8,
    icon: []const u8,
    short: []const u8,
    description: []const u8,

    fn deinit(self: *const Attribute, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.icon);
        gpa.free(self.short);
        gpa.free(self.description);
    }
};

const Attributes = struct {
    attributes: []const Attribute,

    fn deinit(self: *const Attributes, gpa: std.mem.Allocator) void {
        for (self.attributes) |attribute| {
            attribute.deinit(gpa);
        }
        gpa.free(self.attributes);
    }
};

fn gen_skills(init: std.process.Init) !void {
    const skill_schema_file = try std.Io.Dir.cwd().openFile(
        init.io,
        "src/data/skills.json",
        .{ .mode = .read_only },
    );
    defer skill_schema_file.close(init.io);

    var staging_buffer: [1024]u8 = undefined;
    var reader = skill_schema_file.reader(init.io, &staging_buffer);

    var json_reader = std.json.Reader.init(init.gpa, &reader.interface);
    defer json_reader.deinit();

    const skills = try std.json.parseFromTokenSourceLeaky(
        Skills,
        init.gpa,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    );
    defer skills.deinit(init.gpa);

    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(init.gpa);
    try sql.appendUnalignedSlice(init.gpa, "INSERT INTO skills (name, icon, kind, description) VALUES\n");

    for (skills.skills) |skill| {
        const icon_id_query = try std.mem.concat(init.gpa, u8, &.{ "(SELECT id FROM icons WHERE name = '", skill.icon, "' LIMIT 1)" });
        defer init.gpa.free(icon_id_query);

        const kind_id_query = try std.mem.concat(init.gpa, u8, &.{ "(SELECT id FROM skill_kinds WHERE name = '", skill.kind, "' LIMIT 1)" });
        defer init.gpa.free(kind_id_query);

        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", skill.name, "', ", icon_id_query, ", ", kind_id_query, ", $desc$", skill.description, "$desc$),\n" });
        defer init.gpa.free(sql_element);

        try sql.appendUnalignedSlice(init.gpa, sql_element);
    }

    sql.items[sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the skills SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = sql.items, .sub_path = "db/0042-skills.sql", .flags = .{} });
}

const SkillKind = struct {
    const table_name: []const u8 = "skill_kinds";

    title: []const u8,
    type: []const u8,
    description: []const u8,
    @"enum": []const []const u8,

    fn deinit(self: *const SkillKind, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.type);
        gpa.free(self.description);

        for (self.@"enum") |icon_name| {
            gpa.free(icon_name);
        }
        gpa.free(self.@"enum");
    }
};

const Skill = struct {
    name: []const u8,
    icon: []const u8,
    kind: []const u8,
    description: []const u8,

    fn deinit(self: *const Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.icon);
        gpa.free(self.kind);
        gpa.free(self.description);
    }
};

const Skills = struct {
    skills: []const Skill,

    fn deinit(self: *const Skills, gpa: std.mem.Allocator) void {
        for (self.skills) |skill| {
            skill.deinit(gpa);
        }
        gpa.free(self.skills);
    }
};
