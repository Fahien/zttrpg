// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const Io = std.Io;

/// Run all sql files in the `db` directory.
pub fn main(init: std.process.Init) !void {
    var args_it = init.minimal.args.iterate();
    _ = args_it.skip();

    _ = args_it.next() orelse return error.InvalidArguments;
    const icons_out = args_it.next() orelse return error.InvalidArguments;

    const icons_out_dir = try std.Io.Dir.openDirAbsolute(init.io, icons_out, .{});
    defer icons_out_dir.close(init.io);

    const manifest = try icons_out_dir.openFile(init.io, "manifest.txt", .{ .mode = .read_only });
    defer manifest.close(init.io);

    var staging_buffer: [1024]u8 = undefined;
    var reader = manifest.reader(init.io, &staging_buffer);

    const delimiter = "\n";

    var line = std.Io.Writer.Allocating.init(init.gpa);
    defer line.deinit();

    while (true) {
        _ = reader.interface.streamDelimiter(&line.writer, delimiter[0]) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        // Skip delimiter.
        _ = reader.interface.toss(1);
        std.debug.print("{s}\n", .{line.written()});
        line.clearRetainingCapacity();
    }

    if (line.written().len > 0) {
        std.debug.print("{s}\n", .{line.written()});
    }
}
