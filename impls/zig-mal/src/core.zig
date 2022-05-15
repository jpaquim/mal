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
    const tail_items = switch (tail.*) {
        .list => |list| list.items,
        .vector => |vector| vector.items,
        else => return error.EvalConsInvalidOperands,
    };
    var result = try MalType.List.initCapacity(allocator, 1 + tail_items.len);
    result.appendAssumeCapacity(head);
    for (tail_items) |item| {
        result.appendAssumeCapacity(item);
    }
    return MalType.makeList(allocator, result);
}

// TODO: move to linked lists to make this allocate less
pub fn concat(allocator: Allocator, params: MalType.List) !*MalType {
    var result = MalType.List.init(allocator);
    for (params.items) |param| {
        const items = switch (param.*) {
            .list => |list| list.items,
            .vector => |vector| vector.items,
            else => return error.EvalConcatInvalidOperands,
        };
        for (items) |nested| {
            try result.append(nested);
        }
    }
    return MalType.makeList(allocator, result);
}

pub fn nth(param: *MalType, n: *MalType) !*MalType {
    const index = @intCast(usize, try n.asNumber());
    const items = switch (param.*) {
        .list => |list| list.items,
        .vector => |vector| vector.items,
        else => return error.EvalNthInvalidOperands,
    };
    if (index >= items.len) return error.EvalIndexOutOfRange;
    return items[index];
}

// TODO: move to linked lists to make this allocate less
pub fn first(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .nil) return MalType.makeNil(allocator);
    const items = switch (param.*) {
        .list => |list| list.items,
        .vector => |vector| vector.items,
        else => return error.EvalFirstInvalidOperands,
    };
    if (items.len == 0) return MalType.makeNil(allocator);
    return items[0];
}

// TODO: move to linked lists to make this allocate less
pub fn rest(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .nil) return MalType.makeListEmpty(allocator);
    const items = switch (param.*) {
        .list => |list| list.items,
        .vector => |vector| vector.items,
        else => return error.EvalRestInvalidOperands,
    };
    if (items.len == 0) return MalType.makeListEmpty(allocator);
    var result_list = try MalType.List.initCapacity(allocator, items.len - 1);
    for (items[1..]) |item| {
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
    const items = switch (params.items[num_params - 1].*) {
        .list => |list| list.items,
        .vector => |vector| vector.items,
        else => return error.EvalApplyInvalidOperands,
    };
    if (num_params == 2) {
        return function.apply(allocator, items);
    }
    const num_args = num_params - 2 + items.len;
    var args_list = try MalType.List.initCapacity(allocator, num_args);
    for (params.items[1 .. num_params - 2]) |param| {
        args_list.appendAssumeCapacity(param);
    }
    for (items) |param| {
        args_list.appendAssumeCapacity(param);
    }
    return function.apply(allocator, args_list.items);
}

pub fn map(allocator: Allocator, params: MalType.List) !*MalType {
    const function = params.items[0];
    const items = switch (params.items[1].*) {
        .list => |list| list.items,
        .vector => |vector| vector.items,
        else => return error.EvalApplyInvalidOperands,
    };
    var result = try MalType.List.initCapacity(allocator, items.len);
    for (items) |param| {
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

pub fn keyword(allocator: Allocator, param: *MalType) !*MalType {
    return MalType.makeKeyword(allocator, try param.asString());
}

pub fn is_keyword(param: *MalType) bool {
    return param.* == .keyword;
}

pub fn vec(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .vector) return param;
    return MalType.makeVector(allocator, try param.asList());
}

pub fn vector(allocator: Allocator, params: MalType.List) !*MalType {
    var result = try MalType.List.initCapacity(allocator, params.items.len);
    for (params.items) |item| {
        result.appendAssumeCapacity(item);
    }
    return MalType.makeVector(allocator, result);
}

pub fn is_vector(param: *MalType) bool {
    return param.* == .vector;
}

pub fn is_sequential(param: *MalType) bool {
    return param.* == .list or param.* == .vector;
}

pub fn hash_map(allocator: Allocator, params: MalType.List) !*MalType {
    return MalType.makeHashMap(allocator, params);
}

pub fn is_hash_map(param: *MalType) bool {
    return param.* == .hash_map;
}

pub fn assoc(allocator: Allocator, params: MalType.List) !*MalType {
    const hash = try params.items[0].asHashMap();
    const items = params.items[1..];
    var hash_list = try MalType.List.initCapacity(allocator, 2 * hash.count() + items.len);
    var it = hash.iterator();
    while (it.next()) |entry| {
        hash_list.appendAssumeCapacity(entry.key_ptr.*);
        hash_list.appendAssumeCapacity(entry.value_ptr.*);
    }
    for (items) |item| {
        hash_list.appendAssumeCapacity(item);
    }
    return MalType.makeHashMap(allocator, hash_list);
}

pub fn dissoc(allocator: Allocator, params: MalType.List) !*MalType {
    const hash = try params.items[0].asHashMap();
    const keys_to_remove = params.items[1..];
    var hash_list = try MalType.List.initCapacity(allocator, 2 * hash.count());
    var it = hash.iterator();
    while (it.next()) |entry| {
        for (keys_to_remove) |key| {
            if (hash.contains(key)) break;
        } else {
            hash_list.appendAssumeCapacity(entry.key_ptr.*);
            hash_list.appendAssumeCapacity(entry.value_ptr.*);
        }
    }
    return MalType.makeHashMap(allocator, hash_list);
}

pub fn get(allocator: Allocator, param: *MalType, key: *MalType) !*MalType {
    const hash = try param.asHashMap();
    // TODO: check this
    return hash.get(key) orelse MalType.makeNil(allocator);
}

pub fn contains(param: *MalType, key: *MalType) types.EvalError!bool {
    const hash = try param.asHashMap();
    return hash.contains(key);
}

pub fn keys(allocator: Allocator, param: *MalType) !*MalType {
    const hash = try param.asHashMap();
    var result_list = try MalType.List.initCapacity(allocator, hash.count());
    var it = hash.iterator();
    while (it.next()) |entry| {
        result_list.appendAssumeCapacity(entry.key_ptr.*);
    }
    return MalType.makeList(allocator, result_list);
}

pub fn vals(allocator: Allocator, param: *MalType) !*MalType {
    const hash = try param.asHashMap();
    var result_list = try MalType.List.initCapacity(allocator, hash.count());
    var it = hash.iterator();
    while (it.next()) |entry| {
        result_list.appendAssumeCapacity(entry.value_ptr.*);
    }
    return MalType.makeList(allocator, result_list);
}

pub fn time_ms() Number {
    return std.time.milliTimestamp();
}

pub fn conj(allocator: Allocator, param: *MalType, params: MalType.List) !*MalType {
    switch (param.*) {
        .list => |list| {
            var result = try MalType.List.initCapacity(allocator, list.items.len + params.items.len);
            var i = params.items.len;
            while (i > 0) {
                i -= 1;
                const item = params.items[i];
                result.appendAssumeCapacity(item);
            }
            for (list.items) |item| {
                result.appendAssumeCapacity(item);
            }
            return MalType.makeList(allocator, result);
        },
        .vector => |vector| {
            var result = try MalType.Vector.initCapacity(allocator, vector.items.len + params.items.len);
            for (vector.items) |item| {
                result.appendAssumeCapacity(item);
            }
            for (params.items) |item| {
                result.appendAssumeCapacity(item);
            }
            return MalType.makeVector(allocator, result);
        },
        else => return error.EvalConjInvalidOperands,
    }
}

pub fn seq(allocator: Allocator, param: *MalType) !*MalType {
    switch (param.*) {
        .list => |list| return if (list.items.len == 0) MalType.makeNil(allocator) else param,
        .vector => |vector| return if (vector.items.len == 0) MalType.makeNil(allocator) else MalType.makeList(allocator, vector),
        .string => |string| {
            var result = try MalType.List.initCapacity(allocator, string.len);
            for (string) |_, index| {
                result.appendAssumeCapacity(try MalType.makeString(allocator, string[index .. index + 1]));
            }
            return MalType.makeList(allocator, result);
        },
        .nil => return param,
        else => return error.EvalSeqInvalidOperands,
    }
}

pub fn is_string(param: *MalType) bool {
    return param.* == .string;
}

pub fn is_number(param: *MalType) bool {
    return param.* == .number;
}

pub fn is_fn(param: *MalType) bool {
    return param.* == .primitive or (param.* == .closure and !param.closure.is_macro);
}

pub fn is_macro(param: *MalType) bool {
    return param.* == .closure and param.closure.is_macro;
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
    .@"keyword" = keyword,
    .@"keyword?" = is_keyword,
    .@"vec" = vec,
    .@"vector" = vector,
    .@"vector?" = is_vector,
    .@"sequential?" = is_sequential,
    .@"hash-map" = hash_map,
    .@"map?" = is_hash_map,
    .@"assoc" = assoc,
    .@"dissoc" = dissoc,
    .@"get" = get,
    .@"contains?" = contains,
    .@"keys" = keys,
    .@"vals" = vals,
    .@"meta" = not_implemented,
    .@"with-meta" = not_implemented,
    .@"time-ms" = time_ms,
    .@"conj" = conj,
    .@"string?" = is_string,
    .@"number?" = is_number,
    .@"fn?" = is_fn,
    .@"macro?" = is_macro,
    .@"seq" = seq,
};
