// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

/// Run all sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    var args_it = init.minimal.args.iterate();
    _ = args_it.skip();

    const icons_in = args_it.next() orelse return error.InvalidArguments;

    const icons_in_dir = try std.Io.Dir.openDirAbsolute(init.io, icons_in, .{ .iterate = true });
    defer icons_in_dir.close(init.io);

    // Build a registry of all the icons in the `icons_in` directory.
    var icons_registry = std.StringHashMap([]const u8).init(init.gpa);
    defer {
        var it = icons_registry.iterator();
        while (it.next()) |entry| {
            init.gpa.free(entry.key_ptr.*);
            init.gpa.free(entry.value_ptr.*);
        }
        icons_registry.deinit();
    }

    var icons_in_dir_iter = icons_in_dir.iterate();
    while (try icons_in_dir_iter.next(init.io)) |author_entry| {
        // Icons are organizied in a first level of directories.
        if (author_entry.kind == .file) continue;

        std.log.debug("Found author directory: {s}", .{author_entry.name});
        var author_dir = try icons_in_dir.openDir(init.io, author_entry.name, .{ .iterate = true });
        defer author_dir.close(init.io);

        var author_dir_iter = author_dir.iterate();
        while (try author_dir_iter.next(init.io)) |icon_entry| {
            if (icon_entry.kind != .file) continue;
            const icon_stem = std.fs.path.stem(icon_entry.name);
            const icon_ext = std.fs.path.extension(icon_entry.name);

            if (!std.mem.eql(u8, ".svg", icon_ext)) {
                std.log.debug("Skipping non-svg icon: {s}/{s}", .{ author_entry.name, icon_entry.name });
                continue;
            }

            std.log.debug("Found icon: {s}/{s}", .{ author_entry.name, icon_entry.name });

            if (icons_registry.contains(icon_stem)) {
                std.log.debug("Skipping duplicate icon: {s}/{s}", .{ author_entry.name, icon_entry.name });
                continue;
            }

            std.log.debug("Registering icon: {s}", .{icon_stem});
            const icon_name = try init.gpa.dupe(u8, icon_stem);
            const icon_path = try std.fs.path.join(init.gpa, &.{ icons_in, author_entry.name, icon_entry.name });

            try icons_registry.put(icon_name, icon_path);
        }
    }

    const icons_out = args_it.next() orelse return error.InvalidArguments;

    const icons_out_dir = try std.Io.Dir.openDirAbsolute(init.io, icons_out, .{});
    defer icons_out_dir.close(init.io);

    const manifest = try icons_out_dir.openFile(init.io, "manifest.txt", .{ .mode = .read_only });
    defer manifest.close(init.io);

    var manifest_staging_buffer: [1024]u8 = undefined;
    var reader = manifest.reader(init.io, &manifest_staging_buffer);

    const delimiter = "\n";

    var line = std.Io.Writer.Allocating.init(init.gpa);
    defer line.deinit();

    const black_background = "<path d=\"M0 0h512v512H0z\"/>";

    var icons_sql = std.ArrayList(u8).empty;
    defer icons_sql.deinit(init.gpa);
    try icons_sql.appendUnalignedSlice(init.gpa,
        \\CREATE TABLE icons (
        \\   id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        \\   name TEXT NOT NULL,
        \\   CHECK (name <> '')
        \\);
        \\
        \\INSERT INTO icons (name) VALUES
    );

    while (true) {
        _ = reader.interface.streamDelimiter(&line.writer, delimiter[0]) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        // Skip delimiter.
        _ = reader.interface.toss(1);

        const icon_name = line.written();

        // Check if the icon exists in the registry.
        if (!icons_registry.contains(icon_name)) {
            std.log.debug("Icon not found: {s}", .{icon_name});
            line.clearRetainingCapacity();
            continue;
        }

        const icon_sub_path = icons_registry.get(icon_name) orelse {
            std.log.debug("Icon not found in registry: {s}", .{icon_name});
            return error.IconNotFound;
        };

        std.log.info("Copying {s}", .{icon_name});
        const input_icon_bytes = try icons_in_dir.readFileAlloc(init.io, icon_sub_path, init.gpa, .unlimited);
        defer init.gpa.free(input_icon_bytes);

        const icon_bytes_len = std.mem.replacementSize(u8, input_icon_bytes, black_background, "");

        const icon_bytes = try init.gpa.alloc(u8, icon_bytes_len);
        defer init.gpa.free(icon_bytes);

        // Remove black backgorund from icon bytes.
        _ = std.mem.replace(u8, input_icon_bytes, black_background, "", icon_bytes);

        const icon_out_name = try std.mem.concat(init.gpa, u8, &.{ icon_name, ".svg" });
        defer init.gpa.free(icon_out_name);

        const icon_out_file = try icons_out_dir.createFile(init.io, icon_out_name, .{});
        defer icon_out_file.close(init.io);

        var staging_buffer: [1024]u8 = undefined;
        var writer = icon_out_file.writer(init.io, &staging_buffer);
        try writer.interface.writeAll(icon_bytes);
        try writer.flush();

        const sql_element = try std.mem.concat(init.gpa, u8, &.{ "    ('", icon_name, "'),\n" });
        defer init.gpa.free(sql_element);
        try icons_sql.appendUnalignedSlice(init.gpa, sql_element);

        line.clearRetainingCapacity();
    }

    if (line.written().len > 0) {
        std.log.info("{s}\n", .{line.written()});
    }

    icons_sql.items[icons_sql.items.len - 2] = ';'; // Replace the last comma with a semicolon.

    // Overwrite the icons SQL file with the new content.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .data = icons_sql.items, .sub_path = "db/0001-icons.sql", .flags = .{} });
}
