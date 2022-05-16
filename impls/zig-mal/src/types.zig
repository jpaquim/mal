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

pub var current_exception: ?*MalType = null;

pub const MalType = union(enum) {
    pub const Number = i64;

    const Str = []const u8;
    pub const Keyword = Str;
    pub const String = Str;
    pub const Symbol = Str;

    pub const List = std.ArrayList(*MalType);
    pub const Vector = std.ArrayList(*MalType);
    // pub const HashMap = std.StringHashMap(*MalType);
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
        op_alloc_varargs_out_val: fn (allocator: Allocator, args: List) EvalError!*MalType,
        op_alloc_val_varargs_out_val: fn (allocator: Allocator, a: *MalType, args: List) EvalError!*MalType,

        pub fn make(fn_ptr: anytype) Primitive {
            const type_info = @typeInfo(@TypeOf(fn_ptr));
            std.debug.assert(type_info == .Fn);
            const args = type_info.Fn.args;
            const return_type = type_info.Fn.return_type.?;
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
                        // TODO: and return_type == Error!*MalType
                        return .{ .op_alloc_val_out_val = fn_ptr };
                    }
                    if (a_type == Allocator and b_type == List) {
                        // TODO: and return_type == Error!*MalType
                        return .{ .op_alloc_varargs_out_val = fn_ptr };
                    }
                },
                3 => {
                    const a_type = args[0].arg_type.?;
                    const b_type = args[1].arg_type.?;
                    const c_type = args[2].arg_type.?;
                    if (a_type == Allocator and b_type == *MalType and c_type == *MalType) {
                        // TODO: and return_type == Error!*MalType
                        return .{ .op_alloc_val_val_out_val = fn_ptr };
                    }
                    if (a_type == Allocator and b_type == *MalType and c_type == MalType.List) {
                        // TODO: and return_type == Error!*MalType
                        return .{ .op_alloc_val_varargs_out_val = fn_ptr };
                    }
                },
                else => unreachable,
            }
        }
        pub fn apply(primitive: Primitive, allocator: Allocator, args: []*MalType) !*MalType {
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
                    var args_list = try List.initCapacity(allocator, args.len);
                    for (args) |arg| args_list.appendAssumeCapacity(arg);
                    return op(allocator, args_list);
                },
                .op_alloc_val_varargs_out_val => |op| {
                    if (args.len < 2) return error.EvalInvalidOperands;
                    var args_list = try List.initCapacity(allocator, args.len - 1);
                    for (args[1..]) |arg| args_list.appendAssumeCapacity(arg);
                    return op(allocator, args[0], args_list);
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
            if (parameters.len != args.len) {
                return error.EvalInvalidOperands;
            }
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
        NotSlice,
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

    pub fn makeList(allocator: Allocator, list: List) !*MalType {
        return make(allocator, .{ .list = list });
    }

    pub fn makeListEmpty(allocator: Allocator) !*MalType {
        return make(allocator, .{ .list = List.init(allocator) });
    }

    pub fn makeListCapacity(allocator: Allocator, num: usize) !*MalType {
        return make(allocator, .{ .list = try List.initCapacity(allocator, num) });
    }

    pub fn makeListFromSlice(allocator: Allocator, slice: []*MalType) !*MalType {
        var list = try List.initCapacity(allocator, slice.len);
        for (slice) |item| {
            list.appendAssumeCapacity(item);
        }
        return make(allocator, .{ .list = list });
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
        return make(allocator, .{ .vector = vector });
    }

    pub fn makeHashMap(allocator: Allocator, list: List) !*MalType {
        var hash_map = HashMap.init(allocator);
        try hash_map.ensureTotalCapacity(@intCast(u32, list.items.len / 2));
        var i: usize = 0;
        while (i + 1 < list.items.len) : (i += 2) {
            const key = try list.items[i].asKey();
            const value = list.items[i + 1];
            hash_map.putAssumeCapacityNoClobber(key, value);
        }
        return make(allocator, .{ .hash_map = hash_map });
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
        // TODO: handle list == vector correctly
        return @enumToInt(self) == @enumToInt(other.*) and switch (self) {
            .number => |number| number == other.number,
            .keyword => |keyword| std.mem.eql(u8, keyword, other.keyword),
            .string => |string| std.mem.eql(u8, string, other.string),
            .symbol => |symbol| std.mem.eql(u8, symbol, other.symbol),
            .t, .f, .nil => true,
            .list => |list| list.items.len == other.list.items.len and for (list.items) |item, i| {
                if (!item.equals(other.list.items[i])) break false;
            } else true,
            .vector => |vector| vector.items.len == other.vector.items.len and for (vector.items) |item, i| {
                if (!item.equals(other.vector.items[i])) break false;
            } else true,
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
    }

    pub fn isSymbol(self: Self, symbol: []const u8) bool {
        return self == .symbol and std.mem.eql(u8, self.symbol, symbol);
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

    pub fn asSlice(self: Self) ![]*MalType {
        return switch (self) {
            .list => |list| list.items,
            .vector => |vector| vector.items,
            else => error.NotSlice,
        };
    }

    pub fn apply(self: Self, allocator: Allocator, args: []*MalType) !*MalType {
        return switch (self) {
            .primitive => |primitive| primitive.apply(allocator, args),
            .closure => |closure| closure.apply(allocator, args),
            else => error.NotFunction,
        };
    }
};
