const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    inline for (.{
        "spsc_example",
        "spmc_example",
    }) |name| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = true,
        });
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = exe_mod,
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run-" ++ name, "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
