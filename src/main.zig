const std = @import("std");

// Define our C interface to the Swift code
extern fn nano_stats_create(title: [*:0]const u8) ?*anyopaque;
extern fn nano_stats_run(app: ?*anyopaque) void;
extern fn nano_stats_destroy(app: ?*anyopaque) void;

pub fn main() !void {
    // Create the status bar app
    const app = nano_stats_create("NanoStats") orelse {
        std.debug.print("Failed to create status bar app\n", .{});
        return error.AppCreationFailed;
    };

    // Set up cleanup on exit
    defer nano_stats_destroy(app);

    // Run the application (blocks until termination)
    nano_stats_run(app);
}
