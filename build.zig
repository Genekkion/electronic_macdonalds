const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (b.sysroot == null) {
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            b.sysroot = sdk;
        }
    }

    const exe = b.addExecutable(.{
        .name = "electronic_macdonalds",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Lua includes and sources
    exe.root_module.addIncludePath(b.path("lua/src"));
    exe.root_module.addCSourceFiles(.{
        .root = b.path("lua/src"),
        .files = &.{
            "lapi.c",
            "lauxlib.c",
            "lbaselib.c",
            "lcode.c",
            "lcorolib.c",
            "lctype.c",
            "ldblib.c",
            "ldebug.c",
            "ldo.c",
            "ldump.c",
            "lfunc.c",
            "lgc.c",
            "linit.c",
            "liolib.c",
            "llex.c",
            "lmathlib.c",
            "lmem.c",
            "loadlib.c",
            "lobject.c",
            "lopcodes.c",
            "loslib.c",
            "lparser.c",
            "lstate.c",
            "lstring.c",
            "lstrlib.c",
            "ltable.c",
            "ltablib.c",
            "ltm.c",
            "lundump.c",
            "lutf8lib.c",
            "lvm.c",
            "lzio.c",
        },
        .flags = &.{"-std=c99"},
    });

    // macOS Cocoa platform backend
    exe.root_module.addIncludePath(b.path("src/platform"));
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src/platform"),
        .files = &.{
            "macos_window.m",
        },
        .flags = &.{
            "-fobjc-arc",
        },
    });

    if (b.graph.environ_map.get("SDKROOT")) |sdk| {
        b.sysroot = sdk;
        const fw_path = b.fmt("{s}/System/Library/Frameworks", .{sdk});
        exe.root_module.addFrameworkPath(.{ .cwd_relative = fw_path });
    } else {
        exe.root_module.addFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
    }
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("CoreText", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("QuartzCore", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
