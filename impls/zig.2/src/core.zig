const std = @import("std");
const Allocator = std.mem.Allocator;

const printer = @import("./printer.zig");
const printJoin = printer.printJoin;
const reader = @import("./reader.zig");
const types = @import("./types.zig");
const Exception = types.Exception;
const MalObject = types.MalObject;
const MalValue = types.MalValue;
const Number = types.Number;
const Slice = types.Slice;
const Vector = types.Vector;

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

pub fn list(allocator: Allocator, params: Slice) !*MalObject {
    return MalObject.makeList(allocator, params);
}

pub fn is_list(param: *MalObject) bool {
    return param.data == .list;
}

pub fn is_nil(param: *MalObject) bool {
    return param.data == .nil;
}

pub fn is_empty(param: *MalObject) bool {
    return count(param) == 0;
}

pub fn count(param: *MalObject) Number {
    return switch (param.data) {
        .list => |list| @intCast(Number, list.data.len()),
        .vector => |vector| @intCast(Number, vector.data.items.len),
        .nil => 0,
        // TODO: error if not list?
        else => -1,
    };
}

pub fn eql(a: *MalObject, b: *MalObject) bool {
    return a.equals(b);
}

pub fn pr_str(allocator: Allocator, args: Slice) !*MalObject {
    return MalObject.makeString(allocator, try printJoin(allocator, " ", args, true));
}

pub fn str(allocator: Allocator, args: Slice) !*MalObject {
    return MalObject.makeString(allocator, try printJoin(allocator, "", args, false));
}

pub fn prn(allocator: Allocator, args: Slice) !*MalObject {
    const string = try printJoin(allocator, " ", args, true);
    defer allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return MalObject.make(allocator, .nil);
}

pub fn println(allocator: Allocator, args: Slice) !*MalObject {
    const string = try printJoin(allocator, " ", args, false);
    defer allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return MalObject.make(allocator, .nil);
}

pub fn read_string(allocator: Allocator, param: *MalObject) !*MalObject {
    const string = try param.asString();
    return if (reader.read_str(allocator, string)) |result| result else |err| switch (err) {
        error.EmptyInput => MalObject.makeNil(allocator),
        error.EndOfInput => Exception.throwMessage(allocator, "end of input", err),
        error.ListNoClosingTag => Exception.throwMessage(allocator, "unbalanced list form", err),
        error.StringLiteralNoClosingTag => Exception.throwMessage(allocator, "unbalanced string literal", err),
        else => err,
    };
}

pub fn slurp(allocator: Allocator, param: *MalObject) !*MalObject {
    const file_name = try param.asString();
    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    // TODO: revisit global max size definitions
    const max_size = 1 << 16; // 64KiB
    const contents = try file.reader().readAllAlloc(allocator, max_size);
    return MalObject.makeString(allocator, contents);
}

pub fn atom(allocator: Allocator, param: *MalObject) !*MalObject {
    return MalObject.makeAtom(allocator, param);
}

pub fn is_atom(param: *MalObject) bool {
    return param.data == .atom;
}

pub fn deref(param: *MalObject) !*MalObject {
    return param.asAtom();
}

pub fn reset(param: *MalObject, value: *MalObject) !*MalObject {
    _ = try param.asAtom();
    param.data.atom = value;
    return value;
}

pub fn swap(allocator: Allocator, params: Slice) !*MalObject {
    const a = params[0];
    const value = try a.asAtom();
    const function = params[1];

    var args = try std.ArrayList(*MalObject).initCapacity(allocator, params.len - 1);
    args.appendAssumeCapacity(value);
    for (params[2..]) |param| {
        args.appendAssumeCapacity(param);
    }

    const result = try function.apply(allocator, args.items);
    a.data.atom = result;
    return result;
}

pub fn cons(allocator: Allocator, params: Slice) !*MalObject {
    const head = params[0];
    const tail = params[1];
    switch (tail.data) {
        .list => |list| {
            return MalObject.makeListPrependSlice(allocator, list.data, &.{head});
        },
        .vector => |vector| {
            return MalObject.makeListPrependSlice(allocator, try MalObject.listFromSlice(allocator, vector.data.items), &.{head});
        },
        else => return error.EvalConsInvalidOperands,
    }
}

pub fn concat(allocator: Allocator, params: Slice) !*MalObject {
    var result = std.ArrayList(*MalObject).init(allocator);
    for (params) |param| {
        switch (param.data) {
            .list => |list| {
                var it = list.data.first;
                while (it) |node| : (it = node.next) {
                    try result.append(node.data);
                }
            },
            .vector => |vector| {
                for (vector.data.items) |nested| {
                    try result.append(nested);
                }
            },
            else => return error.EvalConcatInvalidOperands,
        }
    }
    return MalObject.makeList(allocator, result.items);
}

pub fn nth(allocator: Allocator, param: *MalObject, index: *MalObject) !*MalObject {
    const n = try index.asNumber();
    return switch (param.data) {
        .list => |list| {
            var i: Number = 0;
            var it = list.data.first;
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
            if (n >= vector.data.items.len)
                return Exception.throwMessage(allocator, "index out of range", error.EvalIndexOutOfRange);
            return vector.data.items[@intCast(usize, n)];
        },
        else => error.EvalNthInvalidOperands,
    };
}

pub fn first(allocator: Allocator, param: *MalObject) !*MalObject {
    return switch (param.data) {
        .nil => MalObject.makeNil(allocator),
        .list => |list| if (list.data.first) |node| node.data else MalObject.makeNil(allocator),
        .vector => |vector| if (vector.data.items.len > 0) vector.data.items[0] else MalObject.makeNil(allocator),
        else => error.EvalFirstInvalidOperands,
    };
}

pub fn rest(allocator: Allocator, param: *MalObject) !*MalObject {
    return switch (param.data) {
        .nil => MalObject.makeListEmpty(allocator),
        .list => |list| if (list.data.first) |node| MalObject.makeListFromNode(allocator, node.next) else MalObject.makeListEmpty(allocator),
        .vector => |vector| if (vector.data.items.len > 1) MalObject.makeList(allocator, vector.data.items[1..]) else MalObject.makeListEmpty(allocator),
        else => error.EvalRestInvalidOperands,
    };
}

pub fn throw(param: *MalObject) !*MalObject {
    return Exception.throw(param, error.MalException);
}

pub fn apply(allocator: Allocator, params: Slice) !*MalObject {
    const num_params = params.len;
    const function = params[0];
    const items = params[num_params - 1].toSlice(allocator) catch return error.EvalApplyInvalidOperands;
    if (num_params == 2) {
        return function.apply(allocator, items);
    }
    const num_args = num_params - 2 + items.len;
    var args_list = try std.ArrayList(*MalObject).initCapacity(allocator, num_args);
    for (params[1 .. num_params - 1]) |param| {
        args_list.appendAssumeCapacity(param);
    }
    for (items) |param| {
        args_list.appendAssumeCapacity(param);
    }
    return function.apply(allocator, args_list.items);
}

pub fn map(allocator: Allocator, params: Slice) !*MalObject {
    const function = params[0];
    const items = params[1].toSlice(allocator) catch return error.EvalMapInvalidOperands;
    var result = try std.ArrayList(*MalObject).initCapacity(allocator, items.len);
    for (items) |param| {
        result.appendAssumeCapacity(try function.apply(allocator, &.{param}));
    }
    return MalObject.makeList(allocator, result.items);
}

pub fn is_true(param: *MalObject) bool {
    return param.data == .t;
}

pub fn is_false(param: *MalObject) bool {
    return param.data == .f;
}

pub fn is_symbol(param: *MalObject) bool {
    return param.data == .symbol;
}

pub fn symbol(allocator: Allocator, param: *MalObject) !*MalObject {
    if (param.data == .symbol) return param;
    return MalObject.makeSymbol(allocator, try param.asString());
}

pub fn keyword(allocator: Allocator, param: *MalObject) !*MalObject {
    if (param.data == .keyword) return param;
    const string = try param.asString();
    return MalObject.makeKeyword(allocator, try MalValue.addKeywordPrefix(allocator, string));
}

pub fn is_keyword(param: *MalObject) bool {
    return param.data == .keyword;
}

pub fn vec(allocator: Allocator, param: *MalObject) !*MalObject {
    if (param.data == .vector) return param;
    return MalObject.makeVector(allocator, try MalObject.arrayListFromList(allocator, param.data.list.data));
}

pub fn vector(allocator: Allocator, params: Slice) !*MalObject {
    return MalObject.makeVectorFromSlice(allocator, params);
}

pub fn is_vector(param: *MalObject) bool {
    return param.data == .vector;
}

pub fn is_sequential(param: *MalObject) bool {
    return param.data == .list or param.data == .vector;
}

pub fn hash_map(allocator: Allocator, params: Slice) !*MalObject {
    return MalObject.makeHashMap(allocator, params);
}

pub fn is_hash_map(param: *MalObject) bool {
    return param.data == .hash_map;
}

pub fn assoc(allocator: Allocator, params: Slice) !*MalObject {
    const hash = try params[0].asHashMap();
    const items = params[1..];
    var hash_list = try std.ArrayList(*MalObject).initCapacity(allocator, 2 * hash.count() + items.len);
    var it = hash.iterator();
    while (it.next()) |entry| {
        hash_list.appendAssumeCapacity(try MalObject.makeKey(allocator, entry.key_ptr.*));
        hash_list.appendAssumeCapacity(entry.value_ptr.*);
    }
    for (items) |item| {
        hash_list.appendAssumeCapacity(item);
    }
    return MalObject.makeHashMap(allocator, hash_list.items);
}

pub fn dissoc(allocator: Allocator, params: Slice) !*MalObject {
    const hash = try params[0].asHashMap();
    const keys_to_remove = params[1..];
    var hash_list = try std.ArrayList(*MalObject).initCapacity(allocator, 2 * hash.count());
    var it = hash.iterator();
    while (it.next()) |entry| {
        for (keys_to_remove) |key| {
            if (std.mem.eql(u8, try key.asKey(), entry.key_ptr.*)) break;
        } else {
            hash_list.appendAssumeCapacity(try MalObject.makeKey(allocator, entry.key_ptr.*));
            hash_list.appendAssumeCapacity(entry.value_ptr.*);
        }
    }
    return MalObject.makeHashMap(allocator, hash_list.items);
}

pub fn get(allocator: Allocator, param: *MalObject, key: *MalObject) !*MalObject {
    if (param.data == .nil) return param;
    const hash = try param.asHashMap();
    return hash.get(try key.asKey()) orelse MalObject.makeNil(allocator);
}

pub fn contains(param: *MalObject, key: *MalObject) types.EvalError!bool {
    const hash = try param.asHashMap();
    return hash.contains(try key.asKey());
}

pub fn keys(allocator: Allocator, param: *MalObject) !*MalObject {
    const hash = try param.asHashMap();
    var result_list = try std.ArrayList(*MalObject).initCapacity(allocator, hash.count());
    var it = hash.keyIterator();
    while (it.next()) |key_ptr| {
        result_list.appendAssumeCapacity(try MalObject.makeKey(allocator, key_ptr.*));
    }
    return MalObject.makeList(allocator, result_list.items);
}

pub fn vals(allocator: Allocator, param: *MalObject) !*MalObject {
    const hash = try param.asHashMap();
    var result_list = try std.ArrayList(*MalObject).initCapacity(allocator, hash.count());
    var it = hash.valueIterator();
    while (it.next()) |value_ptr| {
        result_list.appendAssumeCapacity(value_ptr.*);
    }
    return MalObject.makeList(allocator, result_list.items);
}

const input_buffer_length = 256;

pub fn readline(allocator: Allocator, param: *MalObject) !*MalObject {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var input_buffer: [input_buffer_length]u8 = undefined;
    const prompt = try param.asString();
    try stdout.print("{s}", .{prompt});
    const line = (try stdin.readUntilDelimiterOrEof(&input_buffer, '\n')) orelse return MalObject.makeNil(allocator);
    return MalObject.makeString(allocator, try allocator.dupe(u8, line));
}

pub fn time_ms() Number {
    return std.time.milliTimestamp();
}

pub fn conj(allocator: Allocator, param: *MalObject, params: Slice) !*MalObject {
    switch (param.data) {
        .list => |list| return MalObject.makeListPrependSlice(allocator, list.data, params),
        .vector => |vector| {
            var result = try Vector.initCapacity(allocator, vector.data.items.len + params.len);
            for (vector.data.items) |item| {
                result.appendAssumeCapacity(item);
            }
            for (params) |item| {
                result.appendAssumeCapacity(item);
            }
            return MalObject.makeVector(allocator, result);
        },
        else => return error.EvalConjInvalidOperands,
    }
}

pub fn seq(allocator: Allocator, param: *MalObject) !*MalObject {
    return switch (param.data) {
        .nil => param,
        .list => |list| if (list.data.first != null) param else MalObject.makeNil(allocator),
        .vector => |vector| if (vector.data.items.len > 0) MalObject.makeList(allocator, vector.data.items) else MalObject.makeNil(allocator),
        .string => |string| if (string.len == 0) MalObject.makeNil(allocator) else blk: {
            var result = try std.ArrayList(*MalObject).initCapacity(allocator, string.len);
            for (string) |_, index| {
                result.appendAssumeCapacity(try MalObject.makeString(allocator, string[index .. index + 1]));
            }
            break :blk MalObject.makeList(allocator, result.items);
        },
        else => error.EvalSeqInvalidOperands,
    };
}

pub fn is_string(param: *MalObject) bool {
    return param.data == .string;
}

pub fn is_number(param: *MalObject) bool {
    return param.data == .number;
}

pub fn is_fn(param: *MalObject) bool {
    return param.data == .primitive or (param.data == .closure and !param.data.closure.is_macro);
}

pub fn is_macro(param: *MalObject) bool {
    return param.data == .closure and param.data.closure.is_macro;
}

pub fn meta(allocator: Allocator, param: *MalObject) !*MalObject {
    return param.metadata() orelse try MalObject.makeNil(allocator);
}

pub fn with_meta(allocator: Allocator, param: *MalObject, metadata: *MalObject) !*MalObject {
    var result = try MalObject.make(allocator, param.data);
    if (result.metadataPointer()) |metadata_ptr| {
        metadata_ptr.* = metadata;
    } else return error.EvalWithMetaInvalidOperands;
    return result;
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
    .@"time-ms" = time_ms,
    .@"conj" = conj,
    .@"string?" = is_string,
    .@"number?" = is_number,
    .@"fn?" = is_fn,
    .@"macro?" = is_macro,
    .@"seq" = seq,
    .@"meta" = meta,
    .@"with-meta" = with_meta,
};
