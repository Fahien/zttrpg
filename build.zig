// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    buildIcons(b, target, optimize);
    buildSqls(b, target, optimize);

    const libpq_dep = b.dependency("libpq", .{
        .target = target,
        .optimize = optimize,
    });

    const pq_mod = b.createModule(.{
        .root_source_file = b.path("src/pq.zig"),
        .target = target,
        .optimize = optimize,
    });
    pq_mod.linkLibrary(libpq_dep.artifact("pq"));

    const migration_mod = b.createModule(.{
        .root_source_file = b.path("src/migration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pq", .module = pq_mod },
        },
    });

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
        .imports = &.{
            .{ .name = "pq", .module = pq_mod },
        },
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

    const migration_tests = b.addTest(.{
        .root_module = migration_mod,
    });

    const run_migration_tests = b.addRunArtifact(migration_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_migration_tests.step);
}

fn buildIcons(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const icons_dep = b.dependency("game-icons", .{});

    const icons_mod = b.createModule(.{
        .root_source_file = b.path("src/icons.zig"),
        .target = target,
        .optimize = optimize,
    });

    const icons_exe = b.addExecutable(.{
        .name = "icons",
        .root_module = icons_mod,
    });
    const run_icons = b.addRunArtifact(icons_exe);
    run_icons.addDirectoryArg(icons_dep.path("."));
    run_icons.addArg(b.pathFromRoot("src/web/static/icons"));
    run_icons.has_side_effects = true;

    const icons_step = b.step("icons", "Generate icons");
    icons_step.dependOn(&run_icons.step);
}

fn buildSqls(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const sqls_mod = b.createModule(.{
        .root_source_file = b.path("src/sqls.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sqls_exe = b.addExecutable(.{
        .name = "sqls",
        .root_module = sqls_mod,
    });

    const run_sqls = b.addRunArtifact(sqls_exe);
    run_sqls.has_side_effects = true;

    const sqls_step = b.step("sqls", "Generate SQLs");
    sqls_step.dependOn(&run_sqls.step);
}
