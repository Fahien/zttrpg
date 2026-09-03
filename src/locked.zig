const std = @import("std");

pub fn Locked(comptime T: type) type {
    return struct {
        const Self = @This();

        _io: std.Io,
        mutex: std.Io.Mutex,
        value: T,

        pub fn init(io: std.Io, value: T) Self {
            return Self{
                ._io = io,
                .mutex = .init,
                .value = value,
            };
        }

        pub fn deinit(self: *Self) void {
            self.value.deinit();
        }

        /// Holding the lock is a permission to mutate.
        pub fn lock(self: *Self) std.Io.Cancelable!*T {
            try self.mutex.lock(self._io);
            return &self.value;
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock(self._io);
        }
    };
}

test "many threads bumping one counter agree on the total" {
    var counter = Locked(u32).init(std.testing.io, 0);

    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, bump, .{&counter}) catch unreachable;
    }
    for (threads) |thread| {
        thread.join();
    }
    const value = try counter.lock();
    try std.testing.expectEqual(80_000, value.*);
}

fn bump(counter: *Locked(u32)) std.Io.Cancelable!void {
    for (0..10_000) |_| {
        const guard = try counter.lock();
        guard.* += 1;
        counter.unlock();
    }
}
