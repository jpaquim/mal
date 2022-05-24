const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("./types.zig");
const MalObject = types.MalObject;
const Slice = types.Slice;
const VM = types.VM;
const replaceMultipleOwned = @import("./utils.zig").replaceMultipleOwned;

const Error = error{OutOfMemory};

pub fn pr_str(vm: *VM, value: *const MalObject, print_readably: bool) Error![]const u8 {
    return switch (value.data) {
        .closure => |closure| {
            var result = std.ArrayList(u8).init(vm.allocator);
            const writer = result.writer();
            try writer.writeAll("(fn* (");
            for (closure.parameters.items) |parameter, i| {
                try writer.writeAll(parameter);
                if (i < closure.parameters.items.len - 1) {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll(") ");
            try writer.writeAll(try pr_str(vm, closure.body, print_readably));
            try writer.writeAll(")");
            return result.items;
        },
        .primitive => "#<function>",
        .atom => |atom| {
            var result = std.ArrayList(u8).init(vm.allocator);
            const writer = result.writer();
            try writer.writeAll("(atom ");
            try writer.writeAll(try pr_str(vm, atom, print_readably));
            try writer.writeAll(")");
            return result.items;
        },
        .nil => "nil",
        .t => "true",
        .f => "false",
        .number => |number| try std.fmt.allocPrint(vm.allocator, "{d}", .{number}),
        .keyword => |keyword| try std.fmt.allocPrint(vm.allocator, ":{s}", .{keyword[2..]}),
        .string => |string| if (print_readably) try std.fmt.allocPrint(vm.allocator, "\"{s}\"", .{replaceWithEscapeSequences(vm.allocator, string)}) else string,
        .symbol => |symbol| symbol,
        .list => |list| try printJoinDelims(vm, "(", ")", try vm.sliceFromList(list.data), print_readably),
        .vector => |vector| try printJoinDelims(vm, "[", "]", vector.data.items, print_readably),
        .hash_map => |hash_map| try printJoinDelims(vm, "{", "}", try vm.sliceFromHashMap(hash_map.data), print_readably),
    };
}

fn replaceWithEscapeSequences(allocator: Allocator, str: []const u8) ![]const u8 {
    // replace " with \"
    // replace \ with \\
    // replace newline character with \n
    const needles = .{ "\"", "\\", "\n" };
    const replacements = .{ "\\\"", "\\\\", "\\n" };
    return replaceMultipleOwned(u8, 3, allocator, str, needles, replacements);
}

pub fn printJoin(vm: *VM, separator: []const u8, args: Slice, print_readably: bool) ![]const u8 {
    var printed_args = try std.ArrayList([]const u8).initCapacity(vm.allocator, args.len);
    defer printed_args.deinit();
    for (args) |arg| {
        printed_args.appendAssumeCapacity(try pr_str(vm, arg, print_readably));
    }
    return std.mem.join(vm.allocator, separator, printed_args.items);
}

pub fn printJoinDelims(vm: *VM, delimiter_start: []const u8, delimiter_end: []const u8, args: Slice, print_readably: bool) ![]const u8 {
    var printed_forms = std.ArrayList(u8).init(vm.allocator);
    const writer = printed_forms.writer();

    try writer.writeAll(delimiter_start);
    for (args) |list_form, index| {
        const printed_form = try pr_str(vm, list_form, print_readably);
        try writer.writeAll(printed_form);
        if (index < args.len - 1) {
            try writer.writeAll(" ");
        }
    }
    try writer.writeAll(delimiter_end);

    return printed_forms.items;
}
