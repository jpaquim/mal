const std = @import("std");
const Allocator = std.mem.Allocator;

const printer = @import("./printer.zig");
const printJoin = printer.printJoin;
const reader = @import("./reader.zig");
const types = @import("./types.zig");
const Exception = types.Exception;
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

pub fn list(allocator: Allocator, params: MalType.Slice) !*MalType {
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
    return switch (param.*) {
        .list => |list| @intCast(Number, list.len()),
        .vector => |vector| @intCast(Number, vector.items.len),
        .nil => 0,
        // TODO: error if not list?
        else => -1,
    };
}

pub fn eql(a: *MalType, b: *MalType) bool {
    return a.equals(b);
}

pub fn pr_str(allocator: Allocator, args: MalType.Slice) !*MalType {
    return MalType.makeString(allocator, try printJoin(allocator, " ", args, true));
}

pub fn str(allocator: Allocator, args: MalType.Slice) !*MalType {
    return MalType.makeString(allocator, try printJoin(allocator, "", args, false));
}

pub fn prn(allocator: Allocator, args: MalType.Slice) !*MalType {
    const string = try printJoin(allocator, " ", args, true);
    defer allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return MalType.make(allocator, .nil);
}

pub fn println(allocator: Allocator, args: MalType.Slice) !*MalType {
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
        error.EndOfInput => Exception.throwMessage(allocator, "end of input", err),
        error.ListNoClosingTag => Exception.throwMessage(allocator, "unbalanced list form", err),
        error.StringLiteralNoClosingTag => Exception.throwMessage(allocator, "unbalanced string literal", err),
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

pub fn swap(allocator: Allocator, params: MalType.Slice) !*MalType {
    const a = params[0];
    const value = try a.asAtom();
    const function = params[1];

    var args = try std.ArrayList(*MalType).initCapacity(allocator, params.len - 1);
    args.appendAssumeCapacity(value);
    for (params[2..]) |param| {
        args.appendAssumeCapacity(param);
    }

    const result = try function.apply(allocator, args.items);
    a.atom = result;
    return result;
}

pub fn cons(allocator: Allocator, params: MalType.Slice) !*MalType {
    const head = params[0];
    const tail = params[1];
    switch (tail.*) {
        .list => |list| {
            return MalType.makeListPrependSlice(allocator, list, &.{head});
        },
        .vector => |vector| {
            return MalType.makeListPrependSlice(allocator, try MalType.listFromSlice(allocator, vector.items), &.{head});
        },
        else => return error.EvalConsInvalidOperands,
    }
}

pub fn concat(allocator: Allocator, params: MalType.Slice) !*MalType {
    var result = std.ArrayList(*MalType).init(allocator);
    for (params) |param| {
        switch (param.*) {
            .list => |list| {
                var it = list.first;
                while (it) |node| : (it = node.next) {
                    try result.append(node.data);
                }
            },
            .vector => |vector| {
                for (vector.items) |nested| {
                    try result.append(nested);
                }
            },
            else => return error.EvalConcatInvalidOperands,
        }
    }
    return MalType.makeList(allocator, result.items);
}

pub fn nth(allocator: Allocator, param: *MalType, index: *MalType) !*MalType {
    const n = try index.asNumber();
    return switch (param.*) {
        .list => |list| {
            var i: Number = 0;
            var it = list.first;
            while (it) |node| : ({
                it = node.next;
                i += 1;
            }) {
                if (i == n) return node.data;
            } else {
                return Exception.throwMessage(allocator, "index out of range", error.EvalIndexOutOfRange);
            }
        },
        .vector => |vector| {
            if (n >= vector.items.len)
                return Exception.throwMessage(allocator, "index out of range", error.EvalIndexOutOfRange);
            return vector.items[@intCast(usize, n)];
        },
        else => error.EvalNthInvalidOperands,
    };
}

pub fn first(allocator: Allocator, param: *MalType) !*MalType {
    return switch (param.*) {
        .nil => MalType.makeNil(allocator),
        .list => |list| if (list.first) |node| node.data else MalType.makeNil(allocator),
        .vector => |vector| if (vector.items.len > 0) vector.items[0] else MalType.makeNil(allocator),
        else => error.EvalFirstInvalidOperands,
    };
}

pub fn rest(allocator: Allocator, param: *MalType) !*MalType {
    return switch (param.*) {
        .nil => MalType.makeListEmpty(allocator),
        .list => |list| if (list.first) |node| MalType.makeListFromNode(allocator, node.next) else MalType.makeListEmpty(allocator),
        .vector => |vector| if (vector.items.len > 1) MalType.makeList(allocator, vector.items[1..]) else MalType.makeListEmpty(allocator),
        else => error.EvalRestInvalidOperands,
    };
}

pub fn throw(param: *MalType) !*MalType {
    return Exception.throw(param, error.MalException);
}

pub fn apply(allocator: Allocator, params: MalType.Slice) !*MalType {
    const num_params = params.len;
    const function = params[0];
    const items = params[num_params - 1].toSlice(allocator) catch return error.EvalApplyInvalidOperands;
    if (num_params == 2) {
        return function.apply(allocator, items);
    }
    const num_args = num_params - 2 + items.len;
    var args_list = try std.ArrayList(*MalType).initCapacity(allocator, num_args);
    for (params[1 .. num_params - 1]) |param| {
        args_list.appendAssumeCapacity(param);
    }
    for (items) |param| {
        args_list.appendAssumeCapacity(param);
    }
    return function.apply(allocator, args_list.items);
}

pub fn map(allocator: Allocator, params: MalType.Slice) !*MalType {
    const function = params[0];
    const items = params[1].toSlice(allocator) catch return error.EvalMapInvalidOperands;
    var result = try std.ArrayList(*MalType).initCapacity(allocator, items.len);
    for (items) |param| {
        result.appendAssumeCapacity(try function.apply(allocator, &.{param}));
    }
    return MalType.makeList(allocator, result.items);
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
    if (param.* == .symbol) return param;
    return MalType.makeSymbol(allocator, try param.asString());
}

pub fn keyword(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .keyword) return param;
    const string = try param.asString();
    return MalType.makeKeyword(allocator, try MalType.addKeywordPrefix(allocator, string));
}

pub fn is_keyword(param: *MalType) bool {
    return param.* == .keyword;
}

pub fn vec(allocator: Allocator, param: *MalType) !*MalType {
    if (param.* == .vector) return param;
    return MalType.makeVector(allocator, try MalType.arrayListFromList(allocator, param.list));
}

pub fn vector(allocator: Allocator, params: MalType.Slice) !*MalType {
    return MalType.makeVectorFromSlice(allocator, params);
}

pub fn is_vector(param: *MalType) bool {
    return param.* == .vector;
}

pub fn is_sequential(param: *MalType) bool {
    return param.* == .list or param.* == .vector;
}

pub fn hash_map(allocator: Allocator, params: MalType.Slice) !*MalType {
    return MalType.makeHashMap(allocator, params);
}

pub fn is_hash_map(param: *MalType) bool {
    return param.* == .hash_map;
}

pub fn assoc(allocator: Allocator, params: MalType.Slice) !*MalType {
    const hash = try params[0].asHashMap();
    const items = params[1..];
    var hash_list = try std.ArrayList(*MalType).initCapacity(allocator, 2 * hash.count() + items.len);
    var it = hash.iterator();
    while (it.next()) |entry| {
        hash_list.appendAssumeCapacity(try MalType.makeKey(allocator, entry.key_ptr.*));
        hash_list.appendAssumeCapacity(entry.value_ptr.*);
    }
    for (items) |item| {
        hash_list.appendAssumeCapacity(item);
    }
    return MalType.makeHashMap(allocator, hash_list.items);
}

pub fn dissoc(allocator: Allocator, params: MalType.Slice) !*MalType {
    const hash = try params[0].asHashMap();
    const keys_to_remove = params[1..];
    var hash_list = try std.ArrayList(*MalType).initCapacity(allocator, 2 * hash.count());
    var it = hash.iterator();
    while (it.next()) |entry| {
        for (keys_to_remove) |key| {
            if (std.mem.eql(u8, try key.asKey(), entry.key_ptr.*)) break;
        } else {
            hash_list.appendAssumeCapacity(try MalType.makeKey(allocator, entry.key_ptr.*));
            hash_list.appendAssumeCapacity(entry.value_ptr.*);
        }
    }
    return MalType.makeHashMap(allocator, hash_list.items);
}

pub fn get(allocator: Allocator, param: *MalType, key: *MalType) !*MalType {
    if (param.* == .nil) return param;
    const hash = try param.asHashMap();
    return hash.get(try key.asKey()) orelse MalType.makeNil(allocator);
}

pub fn contains(param: *MalType, key: *MalType) types.EvalError!bool {
    const hash = try param.asHashMap();
    return hash.contains(try key.asKey());
}

pub fn keys(allocator: Allocator, param: *MalType) !*MalType {
    const hash = try param.asHashMap();
    var result_list = try std.ArrayList(*MalType).initCapacity(allocator, hash.count());
    var it = hash.keyIterator();
    while (it.next()) |key_ptr| {
        result_list.appendAssumeCapacity(try MalType.makeKey(allocator, key_ptr.*));
    }
    return MalType.makeList(allocator, result_list.items);
}

pub fn vals(allocator: Allocator, param: *MalType) !*MalType {
    const hash = try param.asHashMap();
    var result_list = try std.ArrayList(*MalType).initCapacity(allocator, hash.count());
    var it = hash.valueIterator();
    while (it.next()) |value_ptr| {
        result_list.appendAssumeCapacity(value_ptr.*);
    }
    return MalType.makeList(allocator, result_list.items);
}

const input_buffer_length = 256;

pub fn readline(allocator: Allocator, param: *MalType) !*MalType {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var input_buffer: [input_buffer_length]u8 = undefined;
    const prompt = try param.asString();
    try stdout.print("{s}", .{prompt});
    const line = (try stdin.readUntilDelimiterOrEof(&input_buffer, '\n')) orelse return MalType.makeNil(allocator);
    return MalType.makeString(allocator, try allocator.dupe(u8, line));
}

pub fn time_ms() Number {
    return std.time.milliTimestamp();
}

pub fn conj(allocator: Allocator, param: *MalType, params: MalType.Slice) !*MalType {
    switch (param.*) {
        .list => |list| return MalType.makeListPrependSlice(allocator, list, params),
        .vector => |vector| {
            var result = try MalType.Vector.initCapacity(allocator, vector.items.len + params.len);
            for (vector.items) |item| {
                result.appendAssumeCapacity(item);
            }
            for (params) |item| {
                result.appendAssumeCapacity(item);
            }
            return MalType.makeVector(allocator, result);
        },
        else => return error.EvalConjInvalidOperands,
    }
}

pub fn seq(allocator: Allocator, param: *MalType) !*MalType {
    switch (param.*) {
        .nil => return param,
        .list => |list| return if (list.first != null) param else MalType.makeNil(allocator),
        .vector => |vector| return if (vector.items.len > 0) MalType.makeList(allocator, vector.items) else MalType.makeNil(allocator),
        .string => |string| {
            var result = try std.ArrayList(*MalType).initCapacity(allocator, string.len);
            for (string) |_, index| {
                result.appendAssumeCapacity(try MalType.makeString(allocator, string[index .. index + 1]));
            }
            return MalType.makeList(allocator, result.items);
        },
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

pub fn not_implemented(allocator: Allocator, params: MalType.Slice) !*MalType {
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
    .@"readline" = readline,
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
