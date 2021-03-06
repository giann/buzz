const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    var exe = b.addExecutable("buzz", "src/main.zig");
    exe.setTarget(target);
    exe.install();
    exe.setBuildMode(build_mode);
    exe.setMainPkgPath(".");

    var lib = b.addSharedLibrary("buzz", "src/buzz_api.zig", .{ .unversioned = {} });
    lib.setTarget(target);
    lib.install();
    lib.setMainPkgPath(".");
    lib.setBuildMode(build_mode);

    b.default_step.dependOn(&exe.step);
    b.default_step.dependOn(&lib.step);

    const lib_paths = [_][]const u8{
        "lib/buzz_std.zig",
        "lib/buzz_io.zig",
        "lib/buzz_gc.zig",
        "lib/buzz_os.zig",
        "lib/buzz_fs.zig",
        "lib/buzz_math.zig",
        "lib/buzz_debug.zig",
    };
    const lib_names = [_][]const u8{
        "std",
        "io",
        "gc",
        "os",
        "fs",
        "math",
        "debug",
    };

    for (lib_paths) |lib_path, index| {
        var std_lib = b.addSharedLibrary(lib_names[index], lib_path, .{ .unversioned = {} });
        std_lib.setTarget(target);
        std_lib.install();
        std_lib.setMainPkgPath(".");
        std_lib.setBuildMode(build_mode);
        std_lib.linkLibrary(lib);
        b.default_step.dependOn(&std_lib.step);
    }

    const play = b.step("run", "Run buzz");
    const run = exe.run();
    run.step.dependOn(b.getInstallStep());
    play.dependOn(&run.step);
}
