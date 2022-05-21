const std = @import("std");
const Allocator = std.mem.Allocator;

const Env = @import("./env.zig").Env;
const printer = @import("./printer.zig");
const types = @import("./types.zig");
const MalObject = types.MalObject;
const VM = types.VM;

pub fn println(str: []const u8) void {
    std.debug.print("{s}\n", .{str});
}

pub fn print_ptr(str: []const u8, ptr: anytype) void {
    std.debug.print("{s} {*}\n", .{ str, ptr });
}

pub fn print_ast(vm: *VM, ast: *const MalObject) void {
    std.debug.print("ast: {s}\n", .{printer.pr_str(vm, ast, true)});
}

pub fn print_env(vm: *VM, env: *Env) void {
    print_ptr("env: ", env);

    var env_it = env.data.iterator();
    while (env_it.next()) |entry| {
        std.debug.print("  '{s}: {s}\n", .{ entry.key_ptr.*, printer.pr_str(vm, entry.value_ptr.*, true) });
    }
    if (env.outer) |outer| {
        print_ptr("outer: ", env.outer.?);
        var outer_env_it = outer.data.iterator();
        while (outer_env_it.next()) |entry| {
            std.debug.print("  '{s}: {s}\n", .{ entry.key_ptr.*, printer.pr_str(vm, entry.value_ptr.*, true) });
        }
    } else println("outer: null");
    println("");
}
