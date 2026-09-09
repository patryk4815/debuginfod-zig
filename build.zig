const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn generatePkgconfig(b: *std.Build, version: std.SemanticVersion) !*std.Build.Step.InstallFile {
    const allocator = b.allocator;
    const version_str = try std.fmt.allocPrint(allocator, "{d}.{d}", .{ version.major, version.minor });

    // The install prefix is no longer known at configure time (the new build
    // system resolves it during the make/install stage), so the generated
    // .pc file derives `prefix` from `${pcfiledir}` at use time instead. Here
    // we only need to substitute @VERSION@.
    const template = @embedFile("upstream/libdebuginfod.pc.in");
    const text = try std.mem.replaceOwned(u8, allocator, template, "@VERSION@", version_str);

    const wf = b.addWriteFiles();
    const pc = wf.add("libdebuginfod.pc", text);
    return b.addInstallFileWithDir(pc, .prefix, "lib/pkgconfig/libdebuginfod.pc");
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = try std.SemanticVersion.parse(manifest.version);

    var linkage: std.builtin.LinkMode = .static;
    const linkage_str = b.option(
        []const u8,
        "linkage",
        "linkage type of result library (default: static), options: static,dynamic",
    ) orelse "";
    if (std.mem.eql(u8, linkage_str, "dynamic")) {
        linkage = .dynamic;
    }

    const zon_module = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/binding.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("build.zig.zon", zon_module);

    const include = b.addInstallHeaderFile(b.path("upstream/debuginfod.h"), "elfutils/debuginfod.h");
    const pkgconfig = try generatePkgconfig(b, version);
    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "debuginfod",
        .root_module = lib_mod,
        .version = version,
    });
    if (linkage == .static) {
        lib.bundle_compiler_rt = true;
        lib.pie = true;
    }
    lib.setVersionScript(b.path("upstream/libdebuginfod.map"));
    lib.step.dependOn(&include.step);
    lib.step.dependOn(&pkgconfig.step);
    b.installArtifact(lib);

    // `debuginfod-find` CLI (see issue #8): thin wrapper over client.zig with
    // the same command line as elfutils' debuginfod-find.
    const find_mod = b.createModule(.{
        .root_source_file = b.path("src/find.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    find_mod.addImport("build.zig.zon", zon_module);
    const find_exe = b.addExecutable(.{
        .name = "debuginfod-find",
        .root_module = find_mod,
        .version = version,
    });
    b.installArtifact(find_exe);

    const run_find = b.addRunArtifact(find_exe);
    run_find.addPassthruArgs();
    const run_step = b.step("run", "Run debuginfod-find (pass args after `--`)");
    run_step.dependOn(&run_find.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    b.installArtifact(lib_unit_tests);

    const find_unit_tests = b.addTest(.{
        .name = "test-find",
        .root_module = find_mod,
    });
    const run_find_unit_tests = b.addRunArtifact(find_unit_tests);
    b.installArtifact(find_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_find_unit_tests.step);
}
