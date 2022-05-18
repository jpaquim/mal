const std = @import("std");
const Allocator = std.mem.Allocator;

const Env = @import("env.zig").Env;
const reader = @import("reader.zig");

pub const EvalError = error{
    EvalDefInvalidOperands,
    EvalDoInvalidOperands,
    EvalIfInvalidOperands,
    EvalLetInvalidOperands,
    EvalQuoteInvalidOperands,
    EvalQuasiquoteInvalidOperands,
    EvalQuasiquoteexpandInvalidOperands,
    EvalUnquoteInvalidOperands,
    EvalSpliceunquoteInvalidOperands,
    EvalDefmacroInvalidOperands,
    EvalMacroexpandInvalidOperands,
    EvalConsInvalidOperands,
    EvalConcatInvalidOperands,
    EvalVecInvalidOperands,
    EvalNthInvalidOperands,
    EvalFirstInvalidOperands,
    EvalRestInvalidOperands,
    EvalApplyInvalidOperands,
    EvalMapInvalidOperands,
    EvalConjInvalidOperands,
    EvalSeqInvalidOperands,
    EvalInvalidOperand,
    EvalInvalidOperands,
    EvalNotSymbolOrFn,
    EnvSymbolNotFound,
    EvalInvalidFnParamsList,
    EvalIndexOutOfRange,
    EvalTryInvalidOperands,
    EvalCatchInvalidOperands,
    EvalTryNoCatch,
    MalException,
    NotImplemented,
} || Allocator.Error || MalType.Primitive.Error;

pub const Exception = struct {
    var current_exception: ?*MalType = null;

    pub fn get() ?*MalType {
        return current_exception;
    }

    pub fn clear() void {
        current_exception = null;
    }

    pub fn throw(value: *MalType, err: EvalError) EvalError {
        current_exception = value;
        return err;
    }

    pub fn throwMessage(allocator: Allocator, message: []const u8, err: EvalError) EvalError {
        current_exception = try MalType.makeString(allocator, message);
        return err;
    }
};

pub const MalType = union(enum) {
    pub const Number = i64;

    const Str = []const u8;
    pub const Keyword = Str;
    pub const String = Str;
    pub const Symbol = Str;

    pub const Slice = []*MalType;

    pub const List = std.SinglyLinkedList(*MalType);
    pub const Vector = std.ArrayList(*MalType);
    pub const HashMap = std.StringHashMap(*MalType);

    pub const Parameters = std.ArrayList(Symbol);
    pub const Primitive = union(enum) {
        pub const Error = error{StreamTooLong} || Allocator.Error || std.fs.File.OpenError || std.fs.File.WriteError || std.os.ReadError || TypeError || reader.ReadError;
        // zero arity primitives
        op_out_num: fn () Number,
        // unary primitives
        op_alloc_val_out_val: fn (allocator: Allocator, a: *MalType) EvalError!*MalType,
        op_val_out_val: fn (a: *MalType) EvalError!*MalType,
        op_val_out_bool: fn (a: *MalType) bool,
        op_val_out_num: fn (a: *MalType) Number,
        // binary primitives
        op_num_num_out_bool: fn (a: Number, b: Number) bool,
        op_num_num_out_num: fn (a: Number, b: Number) Number,
        op_val_val_out_bool: fn (a: *MalType, b: *MalType) bool,
        op_val_val_out_bool_err: fn (a: *MalType, b: *MalType) EvalError!bool,
        op_val_val_out_val: fn (a: *MalType, b: *MalType) EvalError!*MalType,
        op_alloc_val_val_out_val: fn (allocator: Allocator, a: *MalType, b: *MalType) EvalError!*MalType,
        // varargs primitives
        op_alloc_varargs_out_val: fn (allocator: Allocator, args: Slice) EvalError!*MalType,
        op_alloc_val_varargs_out_val: fn (allocator: Allocator, a: *MalType, args: Slice) EvalError!*MalType,

        pub fn make(fn_ptr: anytype) Primitive {
            const type_info = @typeInfo(@TypeOf(fn_ptr));
            std.debug.assert(type_info == .Fn);
            const args = type_info.Fn.args;
            const return_type = type_info.Fn.return_type.?;

            // TODO: check return_type == Error!*MalType
            switch (args.len) {
                0 => {
                    if (return_type == Number)
                        return .{ .op_out_num = fn_ptr };
                },
                1 => {
                    const a_type = args[0].arg_type.?;
                    if (a_type == *MalType) {
                        if (return_type == bool)
                            return .{ .op_val_out_bool = fn_ptr };
                        if (return_type == Number)
                            return .{ .op_val_out_num = fn_ptr };
                        return .{ .op_val_out_val = fn_ptr };
                    }
                },
                2 => {
                    const a_type = args[0].arg_type.?;
                    const b_type = args[1].arg_type.?;
                    if (a_type == Number and b_type == Number) {
                        if (return_type == bool)
                            return .{ .op_num_num_out_bool = fn_ptr };
                        if (return_type == Number)
                            return .{ .op_num_num_out_num = fn_ptr };
                    }
                    if (a_type == *MalType and b_type == *MalType) {
                        if (return_type == bool)
                            return .{ .op_val_val_out_bool = fn_ptr };
                        if (return_type == EvalError!bool)
                            return .{ .op_val_val_out_bool_err = fn_ptr };

                        return .{ .op_val_val_out_val = fn_ptr };
                    }
                    if (a_type == Allocator and b_type == *MalType) {
                        return .{ .op_alloc_val_out_val = fn_ptr };
                    }
                    if (a_type == Allocator and b_type == Slice) {
                        return .{ .op_alloc_varargs_out_val = fn_ptr };
                    }
                },
                3 => {
                    const a_type = args[0].arg_type.?;
                    const b_type = args[1].arg_type.?;
                    const c_type = args[2].arg_type.?;
                    if (a_type == Allocator and b_type == *MalType and c_type == *MalType) {
                        return .{ .op_alloc_val_val_out_val = fn_ptr };
                    }
                    if (a_type == Allocator and b_type == *MalType and c_type == Slice) {
                        return .{ .op_alloc_val_varargs_out_val = fn_ptr };
                    }
                },
                else => unreachable,
            }
        }
        pub fn apply(primitive: Primitive, allocator: Allocator, args: Slice) !*MalType {
            // TODO: can probably be compile-time generated from function type info
            switch (primitive) {
                .op_num_num_out_num => |op| {
                    if (args.len != 2) return error.EvalInvalidOperands;
                    const a = args[0].asNumber() catch return error.EvalInvalidOperand;
                    const b = args[1].asNumber() catch return error.EvalInvalidOperand;
                    return makeNumber(allocator, op(a, b));
                },
                .op_num_num_out_bool => |op| {
                    if (args.len != 2) return error.EvalInvalidOperands;
                    const a = args[0].asNumber() catch return error.EvalInvalidOperand;
                    const b = args[1].asNumber() catch return error.EvalInvalidOperand;
                    return makeBool(allocator, op(a, b));
                },
                .op_val_out_bool => |op| {
                    if (args.len != 1) return error.EvalInvalidOperands;
                    return makeBool(allocator, op(args[0]));
                },
                .op_out_num => |op| {
                    if (args.len != 0) return error.EvalInvalidOperands;
                    return makeNumber(allocator, op());
                },
                .op_val_out_num => |op| {
                    if (args.len != 1) return error.EvalInvalidOperands;
                    return makeNumber(allocator, op(args[0]));
                },
                .op_val_val_out_bool => |op| {
                    if (args.len != 2) return error.EvalInvalidOperands;
                    return makeBool(allocator, op(args[0], args[1]));
                },
                .op_val_val_out_bool_err => |op| {
                    if (args.len != 2) return error.EvalInvalidOperands;
                    return makeBool(allocator, try op(args[0], args[1]));
                },
                .op_val_out_val => |op| {
                    if (args.len != 1) return error.EvalInvalidOperands;
                    return op(args[0]);
                },
                .op_val_val_out_val => |op| {
                    if (args.len != 2) return error.EvalInvalidOperands;
                    return op(args[0], args[1]);
                },
                .op_alloc_val_out_val => |op| {
                    if (args.len != 1) return error.EvalInvalidOperands;
                    return op(allocator, args[0]);
                },
                .op_alloc_val_val_out_val => |op| {
                    if (args.len != 2) return error.EvalInvalidOperands;
                    return op(allocator, args[0], args[1]);
                },
                .op_alloc_varargs_out_val => |op| {
                    return op(allocator, args);
                },
                .op_alloc_val_varargs_out_val => |op| {
                    if (args.len < 2) return error.EvalInvalidOperands;
                    return op(allocator, args[0], args[1..]);
                },
            }
        }
    };

    pub const Closure = struct {
        parameters: Parameters,
        body: *MalType,
        env: *Env,
        eval: fn (allocator: Allocator, ast: *MalType, env: *Env) EvalError!*MalType,
        is_macro: bool = false,

        pub fn apply(closure: Closure, allocator: Allocator, args: []*MalType) !*MalType {
            const parameters = closure.parameters.items;
            // if (parameters.len != args.len) {
            //     return error.EvalInvalidOperands;
            // }
            // convert from a list of MalType.Symbol to a list of valid symbol keys to use in environment init
            var binds = try std.ArrayList([]const u8).initCapacity(allocator, parameters.len);
            for (parameters) |parameter| {
                binds.appendAssumeCapacity(parameter);
            }
            var fn_env_ptr = try closure.env.initChildBindExprs(binds.items, args);
            return closure.eval(allocator, closure.body, fn_env_ptr);
        }
    };

    pub const Atom = *MalType;

    pub const TypeError = error{
        NotAtom,
        NotFunction,
        NotHashMap,
        NotKey,
        NotList,
        NotNumber,
        NotSeq,
        NotSymbol,
        NotString,
    };

    // atoms
    t,
    f,
    nil,
    number: Number,
    keyword: String,
    string: String,
    symbol: Symbol,

    list: List,
    vector: Vector,
    hash_map: HashMap,

    // functions
    primitive: Primitive,
    closure: Closure,

    atom: Atom,

    pub fn make(allocator: Allocator, value: MalType) !*MalType {
        var ptr = try allocator.create(MalType);
        ptr.* = value;
        return ptr;
    }

    pub fn makeBool(allocator: Allocator, b: bool) !*MalType {
        return make(allocator, if (b) .t else .f);
    }

    pub fn makeNumber(allocator: Allocator, num: Number) !*MalType {
        return make(allocator, .{ .number = num });
    }

    pub fn makeKeyword(allocator: Allocator, keyword: []const u8) !*MalType {
        return make(allocator, .{ .keyword = keyword });
    }

    pub fn makeString(allocator: Allocator, string: []const u8) !*MalType {
        return make(allocator, .{ .string = string });
    }

    pub fn makeSymbol(allocator: Allocator, symbol: []const u8) !*MalType {
        return make(allocator, .{ .symbol = symbol });
    }

    pub fn makeAtom(allocator: Allocator, value: *MalType) !*MalType {
        return make(allocator, .{ .atom = value });
    }

    pub fn makeListNode(allocator: Allocator, data: *MalType) !*List.Node {
        var ptr = try allocator.create(List.Node);
        ptr.* = .{ .data = data, .next = null };
        return ptr;
    }

    pub fn makeListEmpty(allocator: Allocator) !*MalType {
        return make(allocator, .{ .list = .{ .first = null } });
    }

    pub fn makeListFromNode(allocator: Allocator, node: ?*List.Node) !*MalType {
        return make(allocator, .{ .list = .{ .first = node } });
    }

    pub fn makeList(allocator: Allocator, slice: []*MalType) !*MalType {
        return make(allocator, .{ .list = try listFromSlice(allocator, slice) });
    }

    pub fn makeListPrependSlice(allocator: Allocator, list: List, slice: Slice) !*MalType {
        var result_list = list;
        for (slice) |item| {
            result_list.prepend(try MalType.makeListNode(allocator, item));
        }
        return make(allocator, .{ .list = result_list });
    }

    pub fn listFromSlice(allocator: Allocator, slice: Slice) !List {
        var list = List{ .first = null };
        var i = slice.len;
        while (i > 0) {
            i -= 1;
            list.prepend(try makeListNode(allocator, slice[i]));
        }
        return list;
    }

    pub fn arrayListFromList(allocator: Allocator, list: List) !std.ArrayList(*MalType) {
        var result = std.ArrayList(*MalType).init(allocator);
        var it = list.first;
        while (it) |node| : (it = node.next) {
            try result.append(node.data);
        }
        return result;
    }

    pub fn sliceFromList(allocator: Allocator, list: List) !Slice {
        return (try arrayListFromList(allocator, list)).items;
    }

    pub fn makeVector(allocator: Allocator, vector: Vector) !*MalType {
        return make(allocator, .{ .vector = vector });
    }

    pub fn makeVectorEmpty(allocator: Allocator) !*MalType {
        return make(allocator, .{ .vector = Vector.init(allocator) });
    }

    pub fn makeVectorCapacity(allocator: Allocator, num: usize) !*MalType {
        return make(allocator, .{ .vector = try Vector.initCapacity(allocator, num) });
    }

    pub fn makeVectorFromSlice(allocator: Allocator, slice: []*MalType) !*MalType {
        var vector = try Vector.initCapacity(allocator, slice.len);
        for (slice) |item| {
            vector.appendAssumeCapacity(item);
        }
        return makeVector(allocator, vector);
    }

    pub fn makeHashMap(allocator: Allocator, slice: Slice) !*MalType {
        var hash_map = HashMap.init(allocator);
        try hash_map.ensureTotalCapacity(@intCast(u32, slice.len / 2));
        var i: usize = 0;
        while (i + 1 < slice.len) : (i += 2) {
            const key = try slice[i].asKey();
            const value = slice[i + 1];
            hash_map.putAssumeCapacity(key, value);
        }
        return make(allocator, .{ .hash_map = hash_map });
    }

    pub fn sliceFromHashMap(allocator: Allocator, hash_map: MalType.HashMap) !Slice {
        var list = try std.ArrayList(*MalType).initCapacity(allocator, hash_map.count() * 2);
        var it = hash_map.iterator();
        while (it.next()) |entry| {
            list.appendAssumeCapacity(try MalType.makeKey(allocator, entry.key_ptr.*));
            list.appendAssumeCapacity(entry.value_ptr.*);
        }
        return list.items;
    }

    pub fn makeNil(allocator: Allocator) !*MalType {
        return make(allocator, .nil);
    }

    pub fn makePrimitive(allocator: Allocator, primitive: anytype) !*MalType {
        return make(allocator, .{ .primitive = Primitive.make(primitive) });
    }

    pub fn makeClosure(allocator: Allocator, closure: Closure) !*MalType {
        return make(allocator, .{ .closure = closure });
    }

    pub fn makeKey(allocator: Allocator, string: Str) !*MalType {
        if (string.len > 2 and std.mem.eql(u8, string[0..2], "ʞ")) return makeKeyword(allocator, string) else return makeString(allocator, string);
    }

    pub fn addKeywordPrefix(allocator: Allocator, string: []const u8) !Keyword {
        return std.mem.concat(allocator, u8, &.{ "ʞ", string });
    }

    pub fn equalsListVector(list: List, vector: Vector) bool {
        const items = vector.items;
        var i: usize = 0;
        var it = list.first;
        return while (it) |node| : ({
            it = node.next;
            i += 1;
        }) {
            if (i >= items.len) break false;
            if (!node.data.equals(items[i])) break false;
        } else i == items.len;
    }

    const Self = @This();

    // pub fn deinit(self: *Self) void {
    //     switch (self.*) {
    //         .list => |list| {
    //             for (list.items) |item| {
    //                 item.deinit();
    //             }
    //             list.deinit();
    //         },
    //         .string, .symbol => |str_alloc| str_alloc.allocator.free(str_alloc.value),
    //         .closure => |closure| {
    //             for (closure.parameters.items) |parameter| {
    //                 parameter.allocator.free(parameter.value);
    //             }
    //             closure.parameters.deinit();
    //             closure.body.deinit();
    //             // closure.env.deinit();
    //         },
    //         else => {},
    //     }
    // }

    // pub fn copy(self: Self, allocator: Allocator) Allocator.Error!*MalType {
    //     return switch (self) {
    //         .list => |list| blk: {
    //             var list_copy = try List.initCapacity(allocator, list.items.len);
    //             for (list.items) |item| {
    //                 list_copy.appendAssumeCapacity(try item.copy(allocator));
    //             }
    //             break :blk makeList(allocator, list_copy);
    //         },
    //         .string => |string| makeString(allocator, try allocator.dupe(u8, string.value)),
    //         .symbol => |symbol| makeSymbol(allocator, try allocator.dupe(u8, symbol.value)),
    //         .closure => |closure| blk: {
    //             var parameters_copy = try Parameters.initCapacity(allocator, closure.parameters.items.len);
    //             for (closure.parameters.items) |item| {
    //                 parameters_copy.appendAssumeCapacity(.{ .value = try allocator.dupe(u8, item.value), .allocator = allocator });
    //             }
    //             break :blk makeClosure(allocator, .{
    //                 .parameters = parameters_copy,
    //                 .body = try closure.body.copy(allocator),
    //                 .env = closure.env,
    //             });
    //         },
    //         // TODO: check this
    //         .atom => |atom| makeAtom(allocator, atom),
    //         else => make(allocator, self),
    //     };
    // }

    pub fn equals(self: Self, other: *const Self) bool {
        // check if values are of the same type
        if (@enumToInt(self) == @enumToInt(other.*)) return switch (self) {
            .number => |number| number == other.number,
            .keyword => |keyword| std.mem.eql(u8, keyword, other.keyword),
            .string => |string| std.mem.eql(u8, string, other.string),
            .symbol => |symbol| std.mem.eql(u8, symbol, other.symbol),
            .t, .f, .nil => true,
            .list => |list| blk: {
                var it = list.first;
                var it_other = other.list.first;
                break :blk while (it) |node| : ({
                    it = node.next;
                    it_other = it_other.?.next;
                }) {
                    if (it_other) |other_node| (if (!node.data.equals(other_node.data)) break false) else break false;
                } else it_other == null;
            },
            .vector => |vector| vector.items.len == other.vector.items.len and for (vector.items) |item, i| {
                if (!item.equals(other.vector.items[i])) break false;
            } else true,
            .hash_map => |hash_map| hash_map.count() == other.hash_map.count() and blk: {
                var it = hash_map.iterator();
                break :blk while (it.next()) |entry| {
                    if (other.hash_map.get(entry.key_ptr.*)) |other_item| {
                        if (!entry.value_ptr.*.equals(other_item)) break false;
                    } else break false;
                } else true;
            },
            .closure => |closure| blk: {
                if (closure.env != other.closure.env) break :blk false;
                if (!closure.body.equals(other.closure.body)) break :blk false;
                if (closure.parameters.items.len != other.closure.parameters.items.len) break :blk false;
                for (closure.parameters.items) |item, i| {
                    if (!std.mem.eql(u8, item, other.closure.parameters.items[i])) break :blk false;
                } else break :blk true;
            },
            .primitive => |primitive| @enumToInt(primitive) == @enumToInt(other.primitive) and
                std.mem.eql(u8, std.mem.asBytes(&primitive), std.mem.asBytes(&other.primitive)),
            else => &self == other,
        };
        if (self == .list and other.* == .vector) {
            return MalType.equalsListVector(self.list, other.vector);
        } else if (self == .vector and other.* == .list) {
            return MalType.equalsListVector(other.list, self.vector);
        } else return false;
    }

    pub fn isSymbol(self: Self, symbol: []const u8) bool {
        return self == .symbol and std.mem.eql(u8, self.symbol, symbol);
    }

    pub fn isListWithFirstSymbol(self: Self, symbol: []const u8) bool {
        return self == .list and self.list.first != null and self.list.first.?.data.isSymbol(symbol);
    }

    pub fn isTruthy(self: Self) bool {
        return !(self == .f or self == .nil);
    }

    pub fn asList(self: Self) !List {
        return switch (self) {
            .list => |list| list,
            else => error.NotList,
        };
    }

    pub fn asHashMap(self: Self) !HashMap {
        return switch (self) {
            .hash_map => |hash_map| hash_map,
            else => error.NotHashMap,
        };
    }

    pub fn asNumber(self: Self) !Number {
        return switch (self) {
            .number => |number| number,
            else => error.NotNumber,
        };
    }

    pub fn asString(self: Self) !String {
        return switch (self) {
            .string => |string| string,
            else => error.NotString,
        };
    }

    pub fn asSymbol(self: Self) !Symbol {
        return switch (self) {
            .symbol => |symbol| symbol,
            else => error.NotSymbol,
        };
    }

    pub fn asAtom(self: Self) !Atom {
        return switch (self) {
            .atom => |atom| atom,
            else => error.NotAtom,
        };
    }

    pub fn asKey(self: Self) ![]const u8 {
        const result = switch (self) {
            .keyword => |keyword| keyword,
            .string => |string| string,
            else => error.NotKey,
        };
        return result;
    }

    pub fn toSlice(self: Self, allocator: Allocator) !Slice {
        return switch (self) {
            .list => |list| MalType.sliceFromList(allocator, list),
            .vector => |vector| vector.items,
            else => error.NotSeq,
        };
    }

    pub fn apply(self: Self, allocator: Allocator, args: Slice) !*MalType {
        return switch (self) {
            .primitive => |primitive| primitive.apply(allocator, args),
            .closure => |closure| closure.apply(allocator, args),
            else => error.NotFunction,
        };
    }
};
