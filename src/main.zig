// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");
const zttrpg = @import("zttrpg");
const pq = @import("pq");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("ZTTRPG\n", .{});

    // TCP skeleton.
    const address = "127.0.0.1";
    const port = 8080;

    const ip_address = try Io.net.IpAddress.parse(address, port);
    var server = try ip_address.listen(init.io, .{ .mode = .stream });
    defer server.deinit(init.io);

    while (true) {
        const conn = try server.accept(init.io);
        defer conn.close(init.io);
        std.debug.print("Accepted connection from {s}:{d}\n", .{ conn.socket.address.ip4.bytes, conn.socket.address.getPort() });
    }
}

fn readCharacters(init: std.process.Init) !void {
    const db = try zttrpg.Database.init();
    defer db.deinit();

    const characters = try db.readCharactersAlloc(init.gpa);
    defer {
        for (characters) |character| {
            character.deinit();
        }
        init.gpa.free(characters);
    }

    std.debug.print("Characters:\n", .{});
    for (characters) |character| {
        std.debug.print("  - {s} (level {d})\n", .{ character.name, character.level });
    }
}
