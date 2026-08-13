// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

/// Generate insertion sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    try gen_icons(init);
    try gen_kin(init);
    try gen_skills(init);
}

fn gen_icons(init: std.process.Init) !void {
    const icons_schema_file = try std.Io.Dir.cwd().openFile(
        init.io,
        "src/data/icon-names.schema.json",
        .{ .mode = .read_only },
    );
    defer icons_schema_file.close(init.io);

    var manifest_staging_buffer: [1024]u8 = undefined;
    var reader = icons_schema_file.reader(init.io, &manifest_staging_buffer);

    var json_reader = std.json.Reader.init(init.gpa, &reader.interface);
    defer json_reader.deinit();

    const icons_schema = std.json.parseFromTokenSourceLeaky(
        IconsSchema,
        init.gpa,
        &json_reader,
        .{ .ignore_unknown_fields = true },
    ) catch |e| {
        // Warn because malformed metadata can be a deeper symptom.
        std.log.warn("{}", .{e});
        return error.MalformedMetadata;
    };
    defer icons_schema.deinit(init.gpa);

    var icons_sql = std.ArrayList(u8).empty;
    defer icons_sql.deinit(init.gpa);
    try icons_sql.appendUnalignedSlice(init.gpa, "INSERT INTO icons (name) VALUES\n");

    for (icons_schema.@"enum") |icon_name| {
        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", icon_name, "'),\n" });
        defer init.gpa.free(sql_element);
        try icons_sql.appendUnalignedSlice(init.gpa, sql_element);
    }

    icons_sql.items[icons_sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the icons SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = icons_sql.items, .sub_path = "db/0001-1-icons.sql", .flags = .{} });
}

const IconsSchema = struct {
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
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = sql.items, .sub_path = "db/0002-1-kins.sql", .flags = .{} });
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
    try sql.appendUnalignedSlice(init.gpa, "INSERT INTO skills (name, icon, description) VALUES\n");

    for (skills.skills) |skill| {
        const icon_id_query = try std.mem.concat(init.gpa, u8, &.{ "(SELECT id FROM icons WHERE name = '", skill.icon, "' LIMIT 1)" });
        defer init.gpa.free(icon_id_query);

        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", skill.name, "', ", icon_id_query, ", $desc$", skill.description, "$desc$),\n" });
        defer init.gpa.free(sql_element);

        try sql.appendUnalignedSlice(init.gpa, sql_element);
    }

    sql.items[sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the skills SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = sql.items, .sub_path = "db/0004-1-skills.sql", .flags = .{} });
}

const Skill = struct {
    name: []const u8,
    icon: []const u8,
    type: []const u8,
    description: []const u8,

    fn deinit(self: *const Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.icon);
        gpa.free(self.type);
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
