const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("./types.zig");
const MalType = types.MalType;
const replaceMultipleOwned = @import("./utils.zig").replaceMultipleOwned;

const Error = error{OutOfMemory};

pub fn pr_str(allocator: Allocator, value: *const MalType, print_readably: bool) Error![]const u8 {
    return switch (value.*) {
        .closure => |closure| {
            var result = std.ArrayList(u8).init(allocator);
            const writer = result.writer();
            try writer.writeAll("(fn* (");
            for (closure.parameters.items) |parameter, i| {
                try writer.writeAll(parameter);
                if (i < closure.parameters.items.len - 1) {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll(") ");
            try writer.writeAll(try pr_str(allocator, closure.body, print_readably));
            try writer.writeAll(")");
            return result.items;
        },
        .primitive => "#<function>",
        .atom => |atom| {
            var result = std.ArrayList(u8).init(allocator);
            const writer = result.writer();
            try writer.writeAll("(atom ");
            try writer.writeAll(try pr_str(allocator, atom, print_readably));
            try writer.writeAll(")");
            return result.items;
        },
        .nil => "nil",
        .t => "true",
        .f => "false",
        .number => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .keyword => |keyword| try std.fmt.allocPrint(allocator, ":{s}", .{keyword[2..]}),
        .string => |string| if (print_readably) try std.fmt.allocPrint(allocator, "\"{s}\"", .{replaceWithEscapeSequences(allocator, string)}) else string,
        .symbol => |symbol| symbol,
        .list => |list| try printJoinDelims(allocator, "(", ")", list, print_readably),
        .vector => |vector| try printJoinDelims(allocator, "[", "]", vector, print_readably),
        .hash_map => |hash_map| try printJoinDelims(allocator, "{", "}", try hashMapToList(allocator, hash_map), print_readably),
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

pub fn printJoin(allocator: Allocator, separator: []const u8, args: MalType.List, print_readably: bool) ![]const u8 {
    var printed_args = try std.ArrayList([]const u8).initCapacity(allocator, args.items.len);
    defer printed_args.deinit();
    for (args.items) |arg| {
        printed_args.appendAssumeCapacity(try pr_str(allocator, arg, print_readably));
    }
    return std.mem.join(allocator, separator, printed_args.items);
}

pub fn printJoinDelims(allocator: Allocator, delimiter_start: []const u8, delimiter_end: []const u8, args: MalType.List, print_readably: bool) ![]const u8 {
    var printed_forms = std.ArrayList(u8).init(allocator);
    const writer = printed_forms.writer();

    try writer.writeAll(delimiter_start);
    for (args.items) |list_form, index| {
        const printed_form = try pr_str(allocator, list_form, print_readably);
        try writer.writeAll(printed_form);
        if (index < args.items.len - 1) {
            try writer.writeAll(" ");
        }
    }
    try writer.writeAll(delimiter_end);

    return printed_forms.items;
}

fn hashMapToList(allocator: Allocator, hash_map: MalType.HashMap) !MalType.List {
    var list = try MalType.List.initCapacity(allocator, hash_map.count() * 2);
    var it = hash_map.iterator();
    while (it.next()) |entry| {
        list.appendAssumeCapacity(try MalType.makeKey(allocator, entry.key_ptr.*));
        list.appendAssumeCapacity(entry.value_ptr.*);
    }
    return list;
}
