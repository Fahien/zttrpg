// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libpq_dep = b.dependency("libpq", .{
        .target = target,
        .optimize = optimize,
    });

    const migration_mod = b.createModule(.{
        .root_source_file = b.path("src/migration.zig"),
        .target = target,
        .optimize = optimize,
    });
    migration_mod.linkLibrary(libpq_dep.artifact("pq"));

    const migration_exe = b.addExecutable(.{
        .name = "migration",
        .root_module = migration_mod,
    });
    b.installArtifact(migration_exe);
    const migration_step = b.step("migration", "Run the migration");

    const run_migration_cmd = b.addRunArtifact(migration_exe);
    migration_step.dependOn(&run_migration_cmd.step);

    const mod = b.addModule("zttrpg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zttrpg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zttrpg", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
