// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .macos) {
        std.debug.print("This application only supports macOS\n", .{});
        return;
    }

    // Create a custom step to build the Swift framework
    const swift_build = b.addSystemCommand(&[_][]const u8{
        "swiftc",
        // Core files
        "macos/Sources/Core/Memory/MemoryTypes.swift",
        "macos/Sources/Core/Memory/SystemMemoryMonitor.swift",
        "macos/Sources/Core/Memory/ProcessMemoryMonitor.swift",
        // UI files
        "macos/Sources/UI/StatusBarView.swift",
        "macos/Sources/UI/MenuBuilder.swift",
        "macos/Sources/UI/ProcessListMenu.swift",
        // App files
        "macos/Sources/App/NanoStatsApp.swift",
        // C Interface
        "macos/Sources/C/CInterface.swift",
        "-emit-library",
        "-o",
        "zig-out/lib/libNanoStats.dylib",
        "-emit-module",
        "-module-name",
        "NanoStats",
        "-parse-as-library",
        "-framework",
        "AppKit",
        "-framework",
        "Foundation",
    });

    // Copy header to the include directory
    const mkdir_cmd = b.addSystemCommand(&[_][]const u8{
        "mkdir", "-p", "zig-out/include",
    });
    const copy_header = b.addSystemCommand(&[_][]const u8{
        "cp", "include/nano_stats.h", "zig-out/include/",
    });
    const copy_modulemap = b.addSystemCommand(&[_][]const u8{
        "cp", "include/module.modulemap", "zig-out/include/",
    });

    copy_header.step.dependOn(&mkdir_cmd.step);
    copy_modulemap.step.dependOn(&mkdir_cmd.step);
    swift_build.step.dependOn(&copy_modulemap.step);

    // Build the Zig executable
    const exe = b.addExecutable(.{
        .name = "nano_stats",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Swift framework
    exe.addLibraryPath(.{ .cwd_relative = "zig-out/lib" });
    exe.addIncludePath(.{ .cwd_relative = "zig-out/include" });
    exe.linkSystemLibrary("NanoStats");

    // Link C standard library and frameworks
    exe.linkLibC();
    exe.linkFramework("Foundation");
    exe.linkFramework("AppKit");

    // Add framework search paths
    exe.addFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
    exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

    // Ensure Swift build happens before Zig build
    exe.step.dependOn(&swift_build.step);

    const plist_install = b.addInstallFile(b.path("macos/NanoStats-Info.plist"), "bin/NanoStats-Info.plist");
    b.getInstallStep().dependOn(&plist_install.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
