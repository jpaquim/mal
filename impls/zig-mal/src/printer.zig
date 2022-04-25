const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("./types.zig");
const MalValue = types.MalValue;
const replaceMultipleOwned = @import("./utils.zig").replaceMultipleOwned;

const Error = error{OutOfMemory};

pub fn pr_str(allocator: Allocator, value: *const MalValue, print_readably: bool) Error![]const u8 {
    // TODO: this needs a significant refactoring to work with an allocator
    // other than arena, not planned for deallocation
    return switch (value.*) {
        // .function => "#<function>",
        .function => |function| switch (function) {
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
                try writer.writeAll(try pr_str(allocator, &.{ .mal_type = closure.body }, print_readably));
                try writer.writeAll(")");
                return result.items;
            },
            else => "#<function>",
        },
        .mal_type => |mal_type| switch (mal_type) {
            .atom => |atom| switch (atom) {
                .nil => "nil",
                .t => "true",
                .f => "false",
                .number => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
                .string => |string| if (print_readably) try std.fmt.allocPrint(allocator, "\"{s}\"", .{replaceWithEscapeSequences(allocator, string)}) else string,
                .symbol => |symbol| symbol,
            },
            .list => |list| {
                var printed_forms = std.ArrayList(u8).init(allocator);
                const writer = printed_forms.writer();

                try writer.writeAll("(");
                for (list.items) |list_form, index| {
                    const printed_form = try pr_str(allocator, &MalValue{ .mal_type = list_form }, print_readably);
                    try writer.writeAll(printed_form);
                    if (index < list.items.len - 1) {
                        try writer.writeAll(" ");
                    }
                }
                try writer.writeAll(")");

                return printed_forms.items;
            },
        },
        .list => |list| {
            var printed_values = std.ArrayList(u8).init(allocator);
            const writer = printed_values.writer();

            try writer.writeAll("(");
            for (list.items) |item, index| {
                const printed_item = try pr_str(allocator, &item, print_readably);
                try writer.writeAll(printed_item);
                if (index < list.items.len - 1) {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll(")");

            return printed_values.items;
        },
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

pub fn printJoin(allocator: Allocator, separator: []const u8, args: MalValue.List, print_readably: bool) ![]const u8 {
    var printed_args = try std.ArrayList([]const u8).initCapacity(allocator, args.items.len);
    defer printed_args.deinit();
    for (args.items) |arg| {
        printed_args.appendAssumeCapacity(try pr_str(allocator, &arg, print_readably));
    }
    return std.mem.join(allocator, separator, printed_args.items);
}