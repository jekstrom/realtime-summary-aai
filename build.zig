// build.zig (example modification)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add the websocket dependency
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-ws-client", // Choose your executable name
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the websocket module to your executable
    exe.root_module.addImport("websocket", websocket_dep.module("websocket"));

    // Link against the C standard library and the ALSA library (libasound)
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("asound");

    // Add the C include path for alsa/asoundlib.h
    // This might not be strictly necessary if it's in the default system paths,
    // but it's good practice to be explicit. You might need to adjust
    // the path "/usr/include" if ALSA headers are installed elsewhere.
    // exe.addIncludePath(b.path("/usr/include")); // Common path for system headers

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
