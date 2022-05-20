const std = @import("std");
const Allocator = std.mem.Allocator;

const Env = @import("env.zig").Env;
const reader = @import("reader.zig");

// base atom types
pub const Number = i64;

const Str = []const u8;
pub const Keyword = Str;
pub const String = Str;
pub const Symbol = Str;

// reference types
pub const Atom = *MalObject;
pub const Metadata = *MalObject;

// collection types
pub const Slice = []*MalObject;

pub const List = std.SinglyLinkedList(*MalObject);
pub const ListMetadata = struct {
    data: List,
    metadata: ?Metadata = null,
};

pub const Vector = std.ArrayList(*MalObject);
pub const VectorMetadata = struct {
    data: Vector,
    metadata: ?Metadata = null,
};

pub const HashMap = std.StringHashMap(*MalObject);
pub const HashMapMetadata = struct {
    data: HashMap,
    metadata: ?Metadata = null,
};

// function types
pub const Parameters = std.ArrayList(Symbol);
pub const Primitive = union(enum) {
    pub const Error = error{StreamTooLong} || Allocator.Error || std.fs.File.OpenError || std.fs.File.WriteError || std.os.ReadError || TypeError || reader.ReadError;
    // zero arity primitives
    op_out_num: fn () Number,
    // unary primitives
    op_alloc_val_out_val: fn (allocator: Allocator, a: *MalObject) EvalError!*MalObject,
    op_val_out_val: fn (a: *MalObject) EvalError!*MalObject,
    op_val_out_bool: fn (a: *MalObject) bool,
    op_val_out_num: fn (a: *MalObject) Number,
    // binary primitives
    op_num_num_out_bool: fn (a: Number, b: Number) bool,
    op_num_num_out_num: fn (a: Number, b: Number) Number,
    op_val_val_out_bool: fn (a: *MalObject, b: *MalObject) bool,
    op_val_val_out_bool_err: fn (a: *MalObject, b: *MalObject) EvalError!bool,
    op_val_val_out_val: fn (a: *MalObject, b: *MalObject) EvalError!*MalObject,
    op_alloc_val_val_out_val: fn (allocator: Allocator, a: *MalObject, b: *MalObject) EvalError!*MalObject,
    // varargs primitives
    op_alloc_varargs_out_val: fn (allocator: Allocator, args: Slice) EvalError!*MalObject,
    op_alloc_val_varargs_out_val: fn (allocator: Allocator, a: *MalObject, args: Slice) EvalError!*MalObject,

    pub fn make(fn_ptr: anytype) Primitive {
        const type_info = @typeInfo(@TypeOf(fn_ptr));
        std.debug.assert(type_info == .Fn);
        const args = type_info.Fn.args;
        const return_type = type_info.Fn.return_type.?;

        // TODO: check return_type == Error!*MalObject
        switch (args.len) {
            0 => {
                if (return_type == Number)
                    return .{ .op_out_num = fn_ptr };
            },
            1 => {
                const a_type = args[0].arg_type.?;
                if (a_type == *MalObject) {
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
                if (a_type == *MalObject and b_type == *MalObject) {
                    if (return_type == bool)
                        return .{ .op_val_val_out_bool = fn_ptr };
                    if (return_type == EvalError!bool)
                        return .{ .op_val_val_out_bool_err = fn_ptr };

                    return .{ .op_val_val_out_val = fn_ptr };
                }
                if (a_type == Allocator and b_type == *MalObject) {
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
                if (a_type == Allocator and b_type == *MalObject and c_type == *MalObject) {
                    return .{ .op_alloc_val_val_out_val = fn_ptr };
                }
                if (a_type == Allocator and b_type == *MalObject and c_type == Slice) {
                    return .{ .op_alloc_val_varargs_out_val = fn_ptr };
                }
            },
            else => unreachable,
        }
    }
    pub fn apply(primitive: Primitive, allocator: Allocator, args: Slice) !*MalObject {
        // TODO: can probably be compile-time generated from function type info
        switch (primitive) {
            .op_num_num_out_num => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                const a = args[0].asNumber() catch return error.EvalInvalidOperand;
                const b = args[1].asNumber() catch return error.EvalInvalidOperand;
                return MalObject.makeNumber(allocator, op(a, b));
            },
            .op_num_num_out_bool => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                const a = args[0].asNumber() catch return error.EvalInvalidOperand;
                const b = args[1].asNumber() catch return error.EvalInvalidOperand;
                return MalObject.makeBool(allocator, op(a, b));
            },
            .op_val_out_bool => |op| {
                if (args.len != 1) return error.EvalInvalidOperands;
                return MalObject.makeBool(allocator, op(args[0]));
            },
            .op_out_num => |op| {
                if (args.len != 0) return error.EvalInvalidOperands;
                return MalObject.makeNumber(allocator, op());
            },
            .op_val_out_num => |op| {
                if (args.len != 1) return error.EvalInvalidOperands;
                return MalObject.makeNumber(allocator, op(args[0]));
            },
            .op_val_val_out_bool => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                return MalObject.makeBool(allocator, op(args[0], args[1]));
            },
            .op_val_val_out_bool_err => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                return MalObject.makeBool(allocator, try op(args[0], args[1]));
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
pub const PrimitiveMetadata = struct {
    data: Primitive,
    metadata: ?Metadata = null,
};

pub const Closure = struct {
    parameters: Parameters,
    body: *MalObject,
    env: *Env,
    eval: fn (allocator: Allocator, ast: *MalObject, env: *Env) EvalError!*MalObject,
    is_macro: bool = false,

    metadata: ?Metadata = null,

    pub fn apply(closure: Closure, allocator: Allocator, args: []*MalObject) !*MalObject {
        const parameters = closure.parameters.items;
        // if (parameters.len != args.len) {
        //     return error.EvalInvalidOperands;
        // }
        // convert from a list of Symbol to a list of valid symbol keys to use in environment init
        var binds = try std.ArrayList([]const u8).initCapacity(allocator, parameters.len);
        for (parameters) |parameter| {
            binds.appendAssumeCapacity(parameter);
        }
        var fn_env_ptr = try closure.env.initChildBindExprs(binds.items, args);
        return closure.eval(allocator, closure.body, fn_env_ptr);
    }
};

pub const MalValue = union(enum) {
    // atoms
    t,
    f,
    nil,
    number: Number,
    keyword: String,
    string: String,
    symbol: Symbol,

    list: ListMetadata,
    vector: VectorMetadata,
    hash_map: HashMapMetadata,

    // functions
    primitive: PrimitiveMetadata,
    closure: Closure,

    atom: Atom,

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
};

pub const MalObject = struct {
    data: MalValue,

    pub fn make(allocator: Allocator, value: MalValue) !*MalObject {
        var ptr = try allocator.create(MalObject);
        ptr.data = value;
        return ptr;
    }

    pub fn makeBool(allocator: Allocator, b: bool) !*MalObject {
        return make(allocator, if (b) .t else .f);
    }

    pub fn makeNumber(allocator: Allocator, num: Number) !*MalObject {
        return make(allocator, .{ .number = num });
    }

    pub fn makeKeyword(allocator: Allocator, keyword: []const u8) !*MalObject {
        return make(allocator, .{ .keyword = keyword });
    }

    pub fn makeString(allocator: Allocator, string: []const u8) !*MalObject {
        return make(allocator, .{ .string = string });
    }

    pub fn makeSymbol(allocator: Allocator, symbol: []const u8) !*MalObject {
        return make(allocator, .{ .symbol = symbol });
    }

    pub fn makeAtom(allocator: Allocator, value: *MalObject) !*MalObject {
        return make(allocator, .{ .atom = value });
    }

    pub fn makeListNode(allocator: Allocator, data: *MalObject) !*List.Node {
        var ptr = try allocator.create(List.Node);
        ptr.* = .{ .data = data, .next = null };
        return ptr;
    }

    pub fn makeListEmpty(allocator: Allocator) !*MalObject {
        return make(allocator, .{ .list = .{ .data = .{ .first = null } } });
    }

    pub fn makeListFromNode(allocator: Allocator, node: ?*List.Node) !*MalObject {
        return make(allocator, .{ .list = .{ .data = .{ .first = node } } });
    }

    pub fn makeList(allocator: Allocator, slice: []*MalObject) !*MalObject {
        return make(allocator, .{ .list = .{ .data = try listFromSlice(allocator, slice) } });
    }

    pub fn makeListPrependSlice(allocator: Allocator, list: List, slice: Slice) !*MalObject {
        var result_list = list;
        for (slice) |item| {
            result_list.prepend(try MalObject.makeListNode(allocator, item));
        }
        return make(allocator, .{ .list = .{ .data = result_list } });
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

    pub fn arrayListFromList(allocator: Allocator, list: List) !std.ArrayList(*MalObject) {
        var result = std.ArrayList(*MalObject).init(allocator);
        var it = list.first;
        while (it) |node| : (it = node.next) {
            try result.append(node.data);
        }
        return result;
    }

    pub fn sliceFromList(allocator: Allocator, list: List) !Slice {
        return (try arrayListFromList(allocator, list)).items;
    }

    pub fn makeVector(allocator: Allocator, vector: Vector) !*MalObject {
        return make(allocator, .{ .vector = .{ .data = vector } });
    }

    pub fn makeVectorEmpty(allocator: Allocator) !*MalObject {
        return make(allocator, .{ .vector = .{ .data = Vector.init(allocator) } });
    }

    pub fn makeVectorCapacity(allocator: Allocator, num: usize) !*MalObject {
        return make(allocator, .{ .vector = .{ .data = try Vector.initCapacity(allocator, num) } });
    }

    pub fn makeVectorFromSlice(allocator: Allocator, slice: []*MalObject) !*MalObject {
        var vector = try Vector.initCapacity(allocator, slice.len);
        for (slice) |item| {
            vector.appendAssumeCapacity(item);
        }
        return makeVector(allocator, vector);
    }

    pub fn makeHashMap(allocator: Allocator, slice: Slice) !*MalObject {
        var hash_map = HashMap.init(allocator);
        try hash_map.ensureTotalCapacity(@intCast(u32, slice.len / 2));
        var i: usize = 0;
        while (i + 1 < slice.len) : (i += 2) {
            const key = try slice[i].asKey();
            const value = slice[i + 1];
            hash_map.putAssumeCapacity(key, value);
        }
        return make(allocator, .{ .hash_map = .{ .data = hash_map } });
    }

    pub fn sliceFromHashMap(allocator: Allocator, hash_map: HashMap) !Slice {
        var list = try std.ArrayList(*MalObject).initCapacity(allocator, hash_map.count() * 2);
        var it = hash_map.iterator();
        while (it.next()) |entry| {
            list.appendAssumeCapacity(try MalObject.makeKey(allocator, entry.key_ptr.*));
            list.appendAssumeCapacity(entry.value_ptr.*);
        }
        return list.items;
    }

    pub fn makeNil(allocator: Allocator) !*MalObject {
        return make(allocator, .nil);
    }

    pub fn makePrimitive(allocator: Allocator, primitive: anytype) !*MalObject {
        return make(allocator, .{ .primitive = .{ .data = Primitive.make(primitive) } });
    }

    pub fn makeClosure(allocator: Allocator, closure: Closure) !*MalObject {
        return make(allocator, .{ .closure = closure });
    }

    pub fn makeKey(allocator: Allocator, string: Str) !*MalObject {
        if (string.len > 2 and std.mem.eql(u8, string[0..2], "ʞ")) return makeKeyword(allocator, string) else return makeString(allocator, string);
    }

    const Self = @This();

    pub fn equals(self: Self, other: *const Self) bool {
        const other_data = other.data;
        // check if values are of the same type
        if (@enumToInt(self.data) == @enumToInt(other_data)) {
            return switch (self.data) {
                .number => |number| number == other_data.number,
                .keyword => |keyword| std.mem.eql(u8, keyword, other_data.keyword),
                .string => |string| std.mem.eql(u8, string, other_data.string),
                .symbol => |symbol| std.mem.eql(u8, symbol, other_data.symbol),
                .t, .f, .nil => true,
                .list => |list| blk: {
                    var it = list.data.first;
                    var it_other = other_data.list.data.first;
                    break :blk while (it) |node| : ({
                        it = node.next;
                        it_other = it_other.?.next;
                    }) {
                        if (it_other) |other_node| (if (!node.data.equals(other_node.data)) break false) else break false;
                    } else it_other == null;
                },
                .vector => |vector| vector.data.items.len == other_data.vector.data.items.len and for (vector.data.items) |item, i| {
                    if (!item.equals(other_data.vector.data.items[i])) break false;
                } else true,
                .hash_map => |hash_map| hash_map.data.count() == other_data.hash_map.data.count() and blk: {
                    var it = hash_map.data.iterator();
                    break :blk while (it.next()) |entry| {
                        if (other_data.hash_map.data.get(entry.key_ptr.*)) |other_item| {
                            if (!entry.value_ptr.*.equals(other_item)) break false;
                        } else break false;
                    } else true;
                },
                .closure => |closure| blk: {
                    if (closure.env != other_data.closure.env) break :blk false;
                    if (!closure.body.equals(other_data.closure.body)) break :blk false;
                    if (closure.parameters.items.len != other_data.closure.parameters.items.len) break :blk false;
                    for (closure.parameters.items) |item, i| {
                        if (!std.mem.eql(u8, item, other_data.closure.parameters.items[i])) break :blk false;
                    } else break :blk true;
                },
                .primitive => |primitive| @enumToInt(primitive.data) == @enumToInt(other_data.primitive.data) and
                    std.mem.eql(u8, std.mem.asBytes(&primitive.data), std.mem.asBytes(&other_data.primitive.data)),
                else => &self == other,
            };
        }
        if (self.data == .list and other_data == .vector) {
            return MalValue.equalsListVector(self.data.list.data, other_data.vector.data);
        } else if (self.data == .vector and other_data == .list) {
            return MalValue.equalsListVector(other_data.list.data, self.data.vector.data);
        } else return false;
    }

    pub fn isSymbol(self: Self, symbol: []const u8) bool {
        return self.data == .symbol and std.mem.eql(u8, self.data.symbol, symbol);
    }

    pub fn isListWithFirstSymbol(self: Self, symbol: []const u8) bool {
        return self.data == .list and self.data.list.data.first != null and self.data.list.data.first.?.data.isSymbol(symbol);
    }

    pub fn isTruthy(self: Self) bool {
        return !(self.data == .f or self.data == .nil);
    }

    pub fn asList(self: Self) !List {
        return switch (self.data) {
            .list => |list| list.data,
            else => error.NotList,
        };
    }

    pub fn asHashMap(self: Self) !HashMap {
        return switch (self.data) {
            .hash_map => |hash_map| hash_map.data,
            else => error.NotHashMap,
        };
    }

    pub fn asNumber(self: Self) !Number {
        return switch (self.data) {
            .number => |number| number,
            else => error.NotNumber,
        };
    }

    pub fn asString(self: Self) !String {
        return switch (self.data) {
            .string => |string| string,
            else => error.NotString,
        };
    }

    pub fn asSymbol(self: Self) !Symbol {
        return switch (self.data) {
            .symbol => |symbol| symbol,
            else => error.NotSymbol,
        };
    }

    pub fn asAtom(self: Self) !Atom {
        return switch (self.data) {
            .atom => |atom| atom,
            else => error.NotAtom,
        };
    }

    pub fn asKey(self: Self) ![]const u8 {
        const result = switch (self.data) {
            .keyword => |keyword| keyword,
            .string => |string| string,
            else => error.NotKey,
        };
        return result;
    }

    pub fn toSlice(self: Self, allocator: Allocator) !Slice {
        return switch (self.data) {
            .list => |list| MalObject.sliceFromList(allocator, list.data),
            .vector => |vector| vector.data.items,
            else => error.NotSeq,
        };
    }

    pub fn apply(self: Self, allocator: Allocator, args: Slice) !*MalObject {
        return switch (self.data) {
            .primitive => |primitive| primitive.data.apply(allocator, args),
            .closure => |closure| closure.apply(allocator, args),
            else => error.NotFunction,
        };
    }

    pub fn metadata(self: Self) ?*MalObject {
        return switch (self.data) {
            .list => |list| list.metadata,
            .vector => |vector| vector.metadata,
            .hash_map => |hash_map| hash_map.metadata,
            .primitive => |primitive| primitive.metadata,
            .closure => |closure| closure.metadata,
            else => null,
        };
    }

    pub fn metadataPointer(self: *Self) ?*?Metadata {
        return switch (self.data) {
            .list => |*list| &list.metadata,
            .vector => |*vector| &vector.metadata,
            .hash_map => |*hash_map| &hash_map.metadata,
            .primitive => |*primitive| &primitive.metadata,
            .closure => |*closure| &closure.metadata,
            else => null,
        };
    }

    pub fn mark(self: *Self) void {
        // if already marked, we're done
        // check this first to avoid recursing on cycles in the object graph.
        if (self.marked) return;

        self.marked = true;
    }
};

pub const Exception = struct {
    var current_exception: ?*MalObject = null;

    pub fn get() ?*MalObject {
        return current_exception;
    }

    pub fn clear() void {
        current_exception = null;
    }

    pub fn throw(value: *MalObject, err: EvalError) EvalError {
        current_exception = value;
        return err;
    }

    pub fn throwMessage(allocator: Allocator, message: []const u8, err: EvalError) EvalError {
        current_exception = try MalObject.makeString(allocator, message);
        return err;
    }
};

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
    EvalWithMetaInvalidOperands,
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
} || Allocator.Error || Primitive.Error;

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
