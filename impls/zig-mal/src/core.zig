const std = @import("std");
const Allocator = std.mem.Allocator;

const printer = @import("./printer.zig");
const printJoin = printer.printJoin;
const reader = @import("./reader.zig");
const types = @import("./types.zig");
const MalType = types.MalType;
const Number = MalType.Number;

pub fn add(a: Number, b: Number) Number {
    return a + b;
}

pub fn subtract(a: Number, b: Number) Number {
    return a - b;
}

pub fn multiply(a: Number, b: Number) Number {
    return a * b;
}

pub fn divide(a: Number, b: Number) Number {
    // TODO: use std.math.divFloor/divTrunc for runtime errors instead of
    // undefined behavior when dividing by zero
    return @divFloor(a, b);
}

pub fn lessThan(a: Number, b: Number) bool {
    return a < b;
}

pub fn lessOrEqual(a: Number, b: Number) bool {
    return a <= b;
}

pub fn greaterThan(a: Number, b: Number) bool {
    return a > b;
}

pub fn greaterOrEqual(a: Number, b: Number) bool {
    return a >= b;
}

pub fn list(allocator: Allocator, params: MalType.List) !*MalType {
    return MalType.makeList(allocator, params);
}

pub fn is_list(param: *MalType) bool {
    return param.* == .list;
}

pub fn is_nil(param: *MalType) bool {
    return param.* == .nil;
}

pub fn is_empty(param: *MalType) bool {
    return count(param) == 0;
}

pub fn count(param: *MalType) Number {
    if (is_list(param))
        return @intCast(Number, param.list.items.len)
    else if (is_nil(param))
        return 0
    else
        // TODO: error if not list?
        return -1;
}

pub fn eql(a: *MalType, b: *MalType) bool {
    return a.equals(b);
}

pub fn pr_str(allocator: Allocator, args: MalType.List) !*MalType {
    return MalType.makeString(allocator, try printJoin(allocator, " ", args, true));
}

pub fn str(allocator: Allocator, args: MalType.List) !*MalType {
    return MalType.makeString(allocator, try printJoin(allocator, "", args, false));
}

pub fn prn(allocator: Allocator, args: MalType.List) !*MalType {
    const string = try printJoin(allocator, " ", args, true);
    defer allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return MalType.make(allocator, .nil);
}

pub fn println(allocator: Allocator, args: MalType.List) !*MalType {
    const string = try printJoin(allocator, " ", args, false);
    defer allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return MalType.make(allocator, .nil);
}

pub fn read_string(allocator: Allocator, param: *MalType) !*MalType {
    const string = try param.asString();
    return if (reader.read_str(allocator, string)) |result| result else |err| switch (err) {
        error.EmptyInput => MalType.makeNil(allocator),
        else => err,
    };
}

pub fn slurp(allocator: Allocator, param: *MalType) !*MalType {
    const file_name = try param.asString();
    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    // TODO: revisit global max size definitions
    const max_size = 1 << 16; // 64KiB
    const contents = try file.reader().readAllAlloc(allocator, max_size);
    return MalType.makeString(allocator, contents);
}

pub fn atom(allocator: Allocator, param: *MalType) !*MalType {
    return MalType.makeAtom(allocator, param);
}

pub fn is_atom(param: *MalType) bool {
    return param.* == .atom;
}

pub fn deref(param: *MalType) !*MalType {
    return param.asAtom();
}

pub fn reset(param: *MalType, value: *MalType) !*MalType {
    _ = try param.asAtom();
    param.atom = value;
    return value;
}

pub fn swap(allocator: Allocator, params: MalType.List) !*MalType {
    const a = params.items[0];
    const value = try a.asAtom();
    const function = params.items[1];

    var args = try std.ArrayList(*MalType).initCapacity(allocator, params.items.len - 1);
    args.appendAssumeCapacity(value);
    for (params.items[2..]) |param| {
        args.appendAssumeCapacity(param);
    }

    const result = try function.apply(allocator, args.items);
    a.atom = result;
    return result;
}

// TODO: move to linked lists to make this allocate less
pub fn cons(allocator: Allocator, params: MalType.List) !*MalType {
    const head = params.items[0];
    const tail = params.items[1];
    var result = try MalType.List.initCapacity(allocator, 1 + tail.list.items.len);
    result.appendAssumeCapacity(head);
    for (tail.list.items) |item| {
        result.appendAssumeCapacity(item);
    }
    return MalType.makeList(allocator, result);
}

// TODO: move to linked lists to make this allocate less
pub fn concat(allocator: Allocator, params: MalType.List) !*MalType {
    var result = MalType.List.init(allocator);
    for (params.items) |param| {
        for ((try param.asList()).items) |nested| {
            try result.append(nested);
        }
    }
    return MalType.makeList(allocator, result);
}

pub fn nth(param: *MalType, n: *MalType) !*MalType {
    const index = @intCast(usize, try n.asNumber());
    const param_list = try param.asList();
    if (index >= param_list.items.len) return error.EvalIndexOutOfRange;
    return param_list.items[index];
}

// TODO: move to linked lists to make this allocate less
pub fn first(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .nil) return MalType.makeNil(allocator);
    const param_list = try param.asList();
    if (param_list.items.len == 0) return MalType.makeNil(allocator);
    return param_list.items[0];
}

// TODO: move to linked lists to make this allocate less
pub fn rest(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .nil) return MalType.makeListEmpty(allocator);
    const param_list = try param.asList();
    if (param_list.items.len == 0) return MalType.makeListEmpty(allocator);
    var result_list = try MalType.List.initCapacity(allocator, param_list.items.len - 1);
    for (param_list.items[1..]) |item| {
        result_list.appendAssumeCapacity(item);
    }
    return MalType.makeList(allocator, result_list);
}

pub fn throw(param: *MalType) !*MalType {
    types.current_exception = param;
    return error.MalException;
}

pub fn apply(allocator: Allocator, params: MalType.List) !*MalType {
    const num_params = params.items.len;
    const function = params.items[0];
    const last_list = try params.items[num_params - 1].asList();
    if (num_params == 2) {
        return function.apply(allocator, last_list.items);
    }
    const num_args = num_params - 2 + last_list.items.len;
    var args_list = try MalType.List.initCapacity(allocator, num_args);
    for (params.items[1 .. num_params - 2]) |param| {
        args_list.appendAssumeCapacity(param);
    }
    for (last_list.items) |param| {
        args_list.appendAssumeCapacity(param);
    }
    return function.apply(allocator, args_list.items);
}

pub fn map(allocator: Allocator, params: MalType.List) !*MalType {
    const function = params.items[0];
    const param_list = try params.items[1].asList();
    var result = try MalType.List.initCapacity(allocator, param_list.items.len);
    for (param_list.items) |param| {
        result.appendAssumeCapacity(try function.apply(allocator, &.{param}));
    }
    return MalType.makeList(allocator, result);
}

pub fn is_true(param: *MalType) bool {
    return param.* == .t;
}

pub fn is_false(param: *MalType) bool {
    return param.* == .f;
}

pub fn is_symbol(param: *MalType) bool {
    return param.* == .symbol;
}

pub fn symbol(allocator: Allocator, param: *MalType) !*MalType {
    return MalType.makeSymbol(allocator, try param.asString());
}

pub fn not_implemented(allocator: Allocator, params: MalType.List) !*MalType {
    _ = allocator;
    _ = params;
    return error.NotImplemented;
}

pub const ns = .{
    .@"+" = add,
    .@"-" = subtract,
    .@"*" = multiply,
    .@"/" = divide,
    .@"<" = lessThan,
    .@"<=" = lessOrEqual,
    .@">" = greaterThan,
    .@">=" = greaterOrEqual,
    .@"=" = eql,
    .@"list" = list,
    .@"list?" = is_list,
    .@"empty?" = is_empty,
    .@"nil?" = is_nil,
    .@"count" = count,
    .@"pr-str" = pr_str,
    .@"str" = str,
    .@"prn" = prn,
    .@"println" = println,
    .@"read-string" = read_string,
    .@"slurp" = slurp,
    .@"atom" = atom,
    .@"atom?" = is_atom,
    .@"deref" = deref,
    .@"reset!" = reset,
    .@"swap!" = swap,
    .@"cons" = cons,
    .@"concat" = concat,
    .@"nth" = nth,
    .@"first" = first,
    .@"rest" = rest,
    .@"throw" = throw,
    .@"apply" = apply,
    .@"map" = map,
    .@"true?" = is_true,
    .@"false?" = is_false,
    .@"symbol?" = is_symbol,
    .@"symbol" = symbol,
    .@"time-ms" = not_implemented,
    .@"meta" = not_implemented,
    .@"with-meta" = not_implemented,
    .@"fn?" = not_implemented,
    .@"string?" = not_implemented,
    .@"number?" = not_implemented,
    .@"seq" = not_implemented,
    .@"conj" = not_implemented,
};
