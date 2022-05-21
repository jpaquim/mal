const std = @import("std");

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
const VM = types.VM;

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

pub fn list(vm: *VM, params: Slice) !*MalObject {
    return vm.makeList(params);
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

pub fn pr_str(vm: *VM, args: Slice) !*MalObject {
    return vm.makeString(try printJoin(vm, " ", args, true));
}

pub fn str(vm: *VM, args: Slice) !*MalObject {
    return vm.makeString(try printJoin(vm, "", args, false));
}

pub fn prn(vm: *VM, args: Slice) !*MalObject {
    const string = try printJoin(vm, " ", args, true);
    defer vm.allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return vm.make(.nil);
}

pub fn println(vm: *VM, args: Slice) !*MalObject {
    const string = try printJoin(vm, " ", args, false);
    defer vm.allocator.free(string);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{string});

    return vm.make(.nil);
}

pub fn read_string(vm: *VM, param: *MalObject) !*MalObject {
    const string = try param.asString();
    return if (reader.read_str(vm, string)) |result| result else |err| switch (err) {
        error.EmptyInput => vm.makeNil(),
        error.EndOfInput => Exception.throwMessage(vm, "end of input", err),
        error.ListNoClosingTag => Exception.throwMessage(vm, "unbalanced list form", err),
        error.StringLiteralNoClosingTag => Exception.throwMessage(vm, "unbalanced string literal", err),
        else => err,
    };
}

pub fn slurp(vm: *VM, param: *MalObject) !*MalObject {
    const file_name = try param.asString();
    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    // TODO: revisit global max size definitions
    const max_size = 1 << 16; // 64KiB
    const contents = try file.reader().readAllAlloc(vm.allocator, max_size);
    return vm.makeString(contents);
}

pub fn atom(vm: *VM, param: *MalObject) !*MalObject {
    return vm.makeAtom(param);
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

pub fn swap(vm: *VM, params: Slice) !*MalObject {
    const a = params[0];
    const value = try a.asAtom();
    const function = params[1];

    var args = try std.ArrayList(*MalObject).initCapacity(vm.allocator, params.len - 1);
    args.appendAssumeCapacity(value);
    for (params[2..]) |param| {
        args.appendAssumeCapacity(param);
    }

    const result = try function.apply(vm, args.items);
    a.data.atom = result;
    return result;
}

pub fn cons(vm: *VM, params: Slice) !*MalObject {
    const head = params[0];
    const tail = params[1];
    switch (tail.data) {
        .list => |list| {
            return vm.makeListPrependSlice(list.data, &.{head});
        },
        .vector => |vector| {
            return vm.makeListPrependSlice(try vm.listFromSlice(vector.data.items), &.{head});
        },
        else => return error.EvalConsInvalidOperands,
    }
}

pub fn concat(vm: *VM, params: Slice) !*MalObject {
    var result = std.ArrayList(*MalObject).init(vm.allocator);
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
    return vm.makeList(result.items);
}

pub fn nth(vm: *VM, param: *MalObject, index: *MalObject) !*MalObject {
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
                return Exception.throwMessage(vm, "index out of range", error.EvalIndexOutOfRange);
            }
        },
        .vector => |vector| {
            if (n >= vector.data.items.len)
                return Exception.throwMessage(vm, "index out of range", error.EvalIndexOutOfRange);
            return vector.data.items[@intCast(usize, n)];
        },
        else => error.EvalNthInvalidOperands,
    };
}

pub fn first(vm: *VM, param: *MalObject) !*MalObject {
    return switch (param.data) {
        .nil => vm.makeNil(),
        .list => |list| if (list.data.first) |node| node.data else vm.makeNil(),
        .vector => |vector| if (vector.data.items.len > 0) vector.data.items[0] else vm.makeNil(),
        else => error.EvalFirstInvalidOperands,
    };
}

pub fn rest(vm: *VM, param: *MalObject) !*MalObject {
    return switch (param.data) {
        .nil => vm.makeListEmpty(),
        .list => |list| if (list.data.first) |node| vm.makeListFromNode(node.next) else vm.makeListEmpty(),
        .vector => |vector| if (vector.data.items.len > 1) vm.makeList(vector.data.items[1..]) else vm.makeListEmpty(),
        else => error.EvalRestInvalidOperands,
    };
}

pub fn throw(param: *MalObject) !*MalObject {
    return Exception.throw(param, error.MalException);
}

pub fn apply(vm: *VM, params: Slice) !*MalObject {
    const num_params = params.len;
    const function = params[0];
    const items = params[num_params - 1].toSlice(vm) catch return error.EvalApplyInvalidOperands;
    if (num_params == 2) {
        return function.apply(vm, items);
    }
    const num_args = num_params - 2 + items.len;
    var args_list = try std.ArrayList(*MalObject).initCapacity(vm.allocator, num_args);
    for (params[1 .. num_params - 1]) |param| {
        args_list.appendAssumeCapacity(param);
    }
    for (items) |param| {
        args_list.appendAssumeCapacity(param);
    }
    return function.apply(vm, args_list.items);
}

pub fn map(vm: *VM, params: Slice) !*MalObject {
    const function = params[0];
    const items = params[1].toSlice(vm) catch return error.EvalMapInvalidOperands;
    var result = try std.ArrayList(*MalObject).initCapacity(vm.allocator, items.len);
    for (items) |param| {
        result.appendAssumeCapacity(try function.apply(vm, &.{param}));
    }
    return vm.makeList(result.items);
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

pub fn symbol(vm: *VM, param: *MalObject) !*MalObject {
    if (param.data == .symbol) return param;
    return vm.makeSymbol(try param.asString());
}

pub fn keyword(vm: *VM, param: *MalObject) !*MalObject {
    if (param.data == .keyword) return param;
    const string = try param.asString();
    return vm.makeKeyword(try MalValue.addKeywordPrefix(vm.allocator, string));
}

pub fn is_keyword(param: *MalObject) bool {
    return param.data == .keyword;
}

pub fn vec(vm: *VM, param: *MalObject) !*MalObject {
    if (param.data == .vector) return param;
    return vm.makeVector(try vm.arrayListFromList(param.data.list.data));
}

pub fn vector(vm: *VM, params: Slice) !*MalObject {
    return vm.makeVectorFromSlice(params);
}

pub fn is_vector(param: *MalObject) bool {
    return param.data == .vector;
}

pub fn is_sequential(param: *MalObject) bool {
    return param.data == .list or param.data == .vector;
}

pub fn hash_map(vm: *VM, params: Slice) !*MalObject {
    return vm.makeHashMap(params);
}

pub fn is_hash_map(param: *MalObject) bool {
    return param.data == .hash_map;
}

pub fn assoc(vm: *VM, params: Slice) !*MalObject {
    const hash = try params[0].asHashMap();
    const items = params[1..];
    var hash_list = try std.ArrayList(*MalObject).initCapacity(vm.allocator, 2 * hash.count() + items.len);
    var it = hash.iterator();
    while (it.next()) |entry| {
        hash_list.appendAssumeCapacity(try vm.makeKey(entry.key_ptr.*));
        hash_list.appendAssumeCapacity(entry.value_ptr.*);
    }
    for (items) |item| {
        hash_list.appendAssumeCapacity(item);
    }
    return vm.makeHashMap(hash_list.items);
}

pub fn dissoc(vm: *VM, params: Slice) !*MalObject {
    const hash = try params[0].asHashMap();
    const keys_to_remove = params[1..];
    var hash_list = try std.ArrayList(*MalObject).initCapacity(vm.allocator, 2 * hash.count());
    var it = hash.iterator();
    while (it.next()) |entry| {
        for (keys_to_remove) |key| {
            if (std.mem.eql(u8, try key.asKey(), entry.key_ptr.*)) break;
        } else {
            hash_list.appendAssumeCapacity(try vm.makeKey(entry.key_ptr.*));
            hash_list.appendAssumeCapacity(entry.value_ptr.*);
        }
    }
    return vm.makeHashMap(hash_list.items);
}

pub fn get(vm: *VM, param: *MalObject, key: *MalObject) !*MalObject {
    if (param.data == .nil) return param;
    const hash = try param.asHashMap();
    return hash.get(try key.asKey()) orelse vm.makeNil();
}

pub fn contains(param: *MalObject, key: *MalObject) types.EvalError!bool {
    const hash = try param.asHashMap();
    return hash.contains(try key.asKey());
}

pub fn keys(vm: *VM, param: *MalObject) !*MalObject {
    const hash = try param.asHashMap();
    var result_list = try std.ArrayList(*MalObject).initCapacity(vm.allocator, hash.count());
    var it = hash.keyIterator();
    while (it.next()) |key_ptr| {
        result_list.appendAssumeCapacity(try vm.makeKey(key_ptr.*));
    }
    return vm.makeList(result_list.items);
}

pub fn vals(vm: *VM, param: *MalObject) !*MalObject {
    const hash = try param.asHashMap();
    var result_list = try std.ArrayList(*MalObject).initCapacity(vm.allocator, hash.count());
    var it = hash.valueIterator();
    while (it.next()) |value_ptr| {
        result_list.appendAssumeCapacity(value_ptr.*);
    }
    return vm.makeList(result_list.items);
}

const input_buffer_length = 256;

pub fn readline(vm: *VM, param: *MalObject) !*MalObject {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var input_buffer: [input_buffer_length]u8 = undefined;
    const prompt = try param.asString();
    try stdout.print("{s}", .{prompt});
    const line = (try stdin.readUntilDelimiterOrEof(&input_buffer, '\n')) orelse return vm.makeNil();
    return vm.makeString(try vm.allocator.dupe(u8, line));
}

pub fn time_ms() Number {
    return std.time.milliTimestamp();
}

pub fn conj(vm: *VM, param: *MalObject, params: Slice) !*MalObject {
    switch (param.data) {
        .list => |list| return vm.makeListPrependSlice(list.data, params),
        .vector => |vector| {
            var result = try Vector.initCapacity(vm.allocator, vector.data.items.len + params.len);
            for (vector.data.items) |item| {
                result.appendAssumeCapacity(item);
            }
            for (params) |item| {
                result.appendAssumeCapacity(item);
            }
            return vm.makeVector(result);
        },
        else => return error.EvalConjInvalidOperands,
    }
}

pub fn seq(vm: *VM, param: *MalObject) !*MalObject {
    return switch (param.data) {
        .nil => param,
        .list => |list| if (list.data.first != null) param else vm.makeNil(),
        .vector => |vector| if (vector.data.items.len > 0) vm.makeList(vector.data.items) else vm.makeNil(),
        .string => |string| if (string.len == 0) vm.makeNil() else blk: {
            var result = try std.ArrayList(*MalObject).initCapacity(vm.allocator, string.len);
            for (string) |_, index| {
                result.appendAssumeCapacity(try vm.makeString(string[index .. index + 1]));
            }
            break :blk vm.makeList(result.items);
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

pub fn meta(vm: *VM, param: *MalObject) !*MalObject {
    return param.metadata() orelse try vm.makeNil();
}

pub fn with_meta(vm: *VM, param: *MalObject, metadata: *MalObject) !*MalObject {
    var result = try vm.make(param.data);
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
