// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Database = @import("../database.zig").Database;

pub const ConfigBody = struct {
    name: []const u8,
    value: []const u8,

    // Mirrors the configs table's CHECK constraints: the database
    // enforces integrity, this gives clients a 400 instead of a 500.
    pub fn validate(self: *const ConfigBody) error{ EmptyName, EmptyValue }!void {
        if (self.name.len == 0) return error.EmptyName;
        if (self.value.len == 0) return error.EmptyValue;
    }
};

pub const ConfigCreate = ConfigBody;
pub const ConfigUpdate = ConfigBody;

/// A rule of the game, read by the database at write time: the triggers in
/// Database triggers look these up by name, and the sheet page reads them to
/// refuse a click before it becomes a request. Values are text so one table
/// holds every kind of setting; whoever reads one parses it.
///
/// Stored exactly as served, so there is no Row. Editable like any resource,
/// which cuts both ways: a row the triggers need cannot be missing, and
/// deleting `attribute_max` makes every spend fail until it is back.
pub const Config = struct {
    pub const Id = u32;
    pub const Create = ConfigCreate;
    pub const Update = ConfigUpdate;
    pub const table_name: []const u8 = "configs";

    pub const attribute_default: []const u8 = "attribute_default";
    pub const attribute_max: []const u8 = "attribute_max";
    pub const profession_skill_minimum: []const u8 = "profession_skill_minimum";

    id: Id = 0,
    name: []const u8,
    value: []const u8,

    /// Reads one setting as a count. Values are text so one table holds every
    /// kind of setting, and a count cannot be negative, so the type refuses a
    /// negative the way the database used to refuse it by hand. A row the
    /// server needs and cannot find is a broken deployment, not a bad request.
    pub fn readCount(db: *const Database, gpa: Allocator, name: []const u8) !u32 {
        for (try db.readAllAlloc(gpa, Config)) |config| {
            if (!std.mem.eql(u8, config.name, name)) continue;
            return std.fmt.parseInt(u32, config.value, 10) catch return error.InvalidConfig;
        }
        return error.MissingConfig;
    }
};

test "ConfigCreate.validate accepts a well-formed config" {
    const config = ConfigCreate{ .name = "attribute_max", .value = "18" };
    try config.validate();
}

test "ConfigCreate.validate rejects an empty name or value" {
    const no_name = ConfigCreate{ .name = "", .value = "18" };
    try std.testing.expectError(error.EmptyName, no_name.validate());

    const no_value = ConfigCreate{ .name = "attribute_max", .value = "" };
    try std.testing.expectError(error.EmptyValue, no_value.validate());
}

test "Config serializes to the JSON wire shape" {
    var out = Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const config = Config{ .id = 3, .name = "attribute_max", .value = "18" };
    try std.json.Stringify.value(config, .{}, &out.writer);

    // The value stays a string on the wire: the page parses the ones it needs.
    try std.testing.expectEqualStrings(
        \\{"id":3,"name":"attribute_max","value":"18"}
    , out.written());
}
