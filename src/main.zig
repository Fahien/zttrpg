// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

const zttrpg = @import("zttrpg");

pub fn main(_: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("ZTTRPG\n", .{});
}
