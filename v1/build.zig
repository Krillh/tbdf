const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_module = b.createModule(.{
        .root_source_file = b.path("src/tbdf.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zig_library = b.addLibrary(.{
        .name = "tbdfv1_zig",
        .root_module = zig_module,
        .linkage = .static,
    });
    b.installArtifact(zig_library);

    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c_library = b.addLibrary(.{
        .name = "tbdfv1",
        .root_module = c_module,
        .linkage = .static,
    });
    b.installArtifact(c_library);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/tbdfv1.h"), "tbdfv1.h").step);

    const tests = b.addTest(.{ .root_module = c_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run TBDFv1 unit tests");
    test_step.dependOn(&run_tests.step);
}
