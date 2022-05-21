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
    op_vm_val_out_val: fn (vm: *VM, a: *MalObject) EvalError!*MalObject,
    op_val_out_val: fn (a: *MalObject) EvalError!*MalObject,
    op_val_out_bool: fn (a: *MalObject) bool,
    op_val_out_num: fn (a: *MalObject) Number,
    // binary primitives
    op_num_num_out_bool: fn (a: Number, b: Number) bool,
    op_num_num_out_num: fn (a: Number, b: Number) Number,
    op_val_val_out_bool: fn (a: *MalObject, b: *MalObject) bool,
    op_val_val_out_bool_err: fn (a: *MalObject, b: *MalObject) EvalError!bool,
    op_val_val_out_val: fn (a: *MalObject, b: *MalObject) EvalError!*MalObject,
    op_vm_val_val_out_val: fn (vm: *VM, a: *MalObject, b: *MalObject) EvalError!*MalObject,
    // varargs primitives
    op_vm_varargs_out_val: fn (vm: *VM, args: Slice) EvalError!*MalObject,
    op_vm_val_varargs_out_val: fn (vm: *VM, a: *MalObject, args: Slice) EvalError!*MalObject,

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
                if (a_type == *VM and b_type == *MalObject) {
                    return .{ .op_vm_val_out_val = fn_ptr };
                }
                if (a_type == *VM and b_type == Slice) {
                    return .{ .op_vm_varargs_out_val = fn_ptr };
                }
            },
            3 => {
                const a_type = args[0].arg_type.?;
                const b_type = args[1].arg_type.?;
                const c_type = args[2].arg_type.?;
                if (a_type == *VM and b_type == *MalObject and c_type == *MalObject) {
                    return .{ .op_vm_val_val_out_val = fn_ptr };
                }
                if (a_type == *VM and b_type == *MalObject and c_type == Slice) {
                    return .{ .op_vm_val_varargs_out_val = fn_ptr };
                }
            },
            else => unreachable,
        }
    }
    pub fn apply(primitive: Primitive, vm: *VM, args: Slice) !*MalObject {
        // TODO: can probably be compile-time generated from function type info
        switch (primitive) {
            .op_num_num_out_num => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                const a = args[0].asNumber() catch return error.EvalInvalidOperand;
                const b = args[1].asNumber() catch return error.EvalInvalidOperand;
                return vm.makeNumber(op(a, b));
            },
            .op_num_num_out_bool => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                const a = args[0].asNumber() catch return error.EvalInvalidOperand;
                const b = args[1].asNumber() catch return error.EvalInvalidOperand;
                return vm.makeBool(op(a, b));
            },
            .op_val_out_bool => |op| {
                if (args.len != 1) return error.EvalInvalidOperands;
                return vm.makeBool(op(args[0]));
            },
            .op_out_num => |op| {
                if (args.len != 0) return error.EvalInvalidOperands;
                return vm.makeNumber(op());
            },
            .op_val_out_num => |op| {
                if (args.len != 1) return error.EvalInvalidOperands;
                return vm.makeNumber(op(args[0]));
            },
            .op_val_val_out_bool => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                return vm.makeBool(op(args[0], args[1]));
            },
            .op_val_val_out_bool_err => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                return vm.makeBool(try op(args[0], args[1]));
            },
            .op_val_out_val => |op| {
                if (args.len != 1) return error.EvalInvalidOperands;
                return op(args[0]);
            },
            .op_val_val_out_val => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                return op(args[0], args[1]);
            },
            .op_vm_val_out_val => |op| {
                if (args.len != 1) return error.EvalInvalidOperands;
                return op(vm, args[0]);
            },
            .op_vm_val_val_out_val => |op| {
                if (args.len != 2) return error.EvalInvalidOperands;
                return op(vm, args[0], args[1]);
            },
            .op_vm_varargs_out_val => |op| {
                return op(vm, args);
            },
            .op_vm_val_varargs_out_val => |op| {
                if (args.len < 2) return error.EvalInvalidOperands;
                return op(vm, args[0], args[1..]);
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
    eval: fn (vm: *VM, ast: *MalObject, env: *Env) EvalError!*MalObject,
    is_macro: bool = false,

    metadata: ?Metadata = null,

    pub fn apply(closure: Closure, vm: *VM, args: []*MalObject) !*MalObject {
        const parameters = closure.parameters.items;
        // if (parameters.len != args.len) {
        //     return error.EvalInvalidOperands;
        // }
        // convert from a list of Symbol to a list of valid symbol keys to use in environment init
        var binds = try std.ArrayList([]const u8).initCapacity(vm.allocator, parameters.len);
        for (parameters) |parameter| {
            binds.appendAssumeCapacity(parameter);
        }
        var fn_env_ptr = try closure.env.initChildBindExprs(binds.items, args);
        return closure.eval(vm, closure.body, fn_env_ptr);
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
    marked: bool,
    next: ?*MalObject,

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

    pub fn toSlice(self: Self, vm: *VM) !Slice {
        return switch (self.data) {
            .list => |list| vm.sliceFromList(list.data),
            .vector => |vector| vector.data.items,
            else => error.NotSeq,
        };
    }

    pub fn apply(self: Self, vm: *VM, args: Slice) !*MalObject {
        return switch (self.data) {
            .primitive => |primitive| primitive.data.apply(vm, args),
            .closure => |closure| closure.apply(vm, args),
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

        switch (self.data) {
            .list => |*list| {
                var it = list.data.first;
                while (it) |node| : (it = node.next) node.data.mark();
                if (list.metadata) |meta| meta.mark();
            },
            .vector => |*vector| {
                for (vector.data.items) |item| item.mark();
                if (vector.metadata) |meta| meta.mark();
            },
            .hash_map => |*hash_map| {
                var it = hash_map.data.iterator();
                while (it.next()) |*entry| {
                    entry.value_ptr.*.mark();
                    // entry.key_ptr.*.mark();
                }
                if (hash_map.metadata) |meta| meta.mark();
            },
            .atom => |atom| atom.mark(),
            .closure => |closure| {
                closure.body.mark();
                var it = closure.env.data.iterator();
                while (it.next()) |*entry| {
                    entry.value_ptr.*.mark();
                }
                if (closure.metadata) |meta| meta.mark();
            },
            .primitive => |primitive| {
                if (primitive.metadata) |meta| meta.mark();
            },
            else => {},
        }
    }
};

pub const VM = struct {
    const init_obj_num_max = 8;

    allocator: Allocator,
    envs: std.ArrayList(*Env),
    first_object: ?*MalObject = null,
    num_objects: i32 = 0,
    max_objects: i32 = init_obj_num_max,

    pub fn init(allocator: Allocator) VM {
        return .{ .allocator = allocator, .envs = std.ArrayList(*Env).init(allocator) };
    }

    pub fn deinit(vm: *VM) void {
        vm.sweep();
        for (vm.envs.items) |env| {
            env.deinit();
        }
    }

    pub fn addEnv(vm: *VM, env: *Env) !void {
        try vm.envs.append(env);
    }

    pub fn gc(vm: *VM) void {
        const num_objects = vm.num_objects;

        vm.markAll();
        vm.sweep();

        vm.max_objects = if (vm.num_objects == 0) init_obj_num_max else vm.num_objects * 2;

        std.debug.print("Collected {} objects, {} remaining\n", .{ num_objects - vm.num_objects, vm.num_objects });
    }

    pub fn markAll(vm: *VM) void {
        for (vm.envs.items) |env| {
            var it = env.data.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.mark();
            }
        }
    }

    pub fn sweep(vm: *VM) void {
        var object_ptr = &vm.first_object;
        while (object_ptr.*) |object| {
            if (!object.marked) {
                object_ptr.* = object.next;
                vm.allocator.destroy(object);
                vm.num_objects -= 1;
            } else {
                if (object.data != .primitive) {
                    object.marked = false;
                }
                object_ptr = &object.next;
            }
        }
    }

    pub fn make(vm: *VM, value: MalValue) !*MalObject {
        if (vm.num_objects == vm.max_objects) vm.gc();

        var object = try vm.allocator.create(MalObject);
        object.* = .{
            .data = value,
            .marked = false,
            .next = vm.first_object,
        };
        vm.first_object = object;
        vm.num_objects += 1;
        return object;
    }

    pub fn makeBool(vm: *VM, b: bool) !*MalObject {
        return vm.make(if (b) .t else .f);
    }

    pub fn makeNumber(vm: *VM, num: Number) !*MalObject {
        return vm.make(.{ .number = num });
    }

    pub fn makeKeyword(vm: *VM, keyword: []const u8) !*MalObject {
        return vm.make(.{ .keyword = keyword });
    }

    pub fn makeString(vm: *VM, string: []const u8) !*MalObject {
        return vm.make(.{ .string = string });
    }

    pub fn makeSymbol(vm: *VM, symbol: []const u8) !*MalObject {
        return vm.make(.{ .symbol = symbol });
    }

    pub fn makeAtom(vm: *VM, value: *MalObject) !*MalObject {
        return vm.make(.{ .atom = value });
    }

    pub fn makeListNode(vm: *VM, data: *MalObject) !*List.Node {
        var ptr = try vm.allocator.create(List.Node);
        ptr.* = .{ .data = data, .next = null };
        return ptr;
    }

    pub fn makeListEmpty(vm: *VM) !*MalObject {
        return vm.make(.{ .list = .{ .data = .{ .first = null } } });
    }

    pub fn makeListFromNode(vm: *VM, node: ?*List.Node) !*MalObject {
        return vm.make(.{ .list = .{ .data = .{ .first = node } } });
    }

    pub fn makeList(vm: *VM, slice: []*MalObject) !*MalObject {
        return vm.make(.{ .list = .{ .data = try vm.listFromSlice(slice) } });
    }

    pub fn makeListPrependSlice(vm: *VM, list: List, slice: Slice) !*MalObject {
        var result_list = list;
        for (slice) |item| {
            result_list.prepend(try vm.makeListNode(item));
        }
        return vm.make(.{ .list = .{ .data = result_list } });
    }

    pub fn listFromSlice(vm: *VM, slice: Slice) !List {
        var list = List{ .first = null };
        var i = slice.len;
        while (i > 0) {
            i -= 1;
            list.prepend(try vm.makeListNode(slice[i]));
        }
        return list;
    }

    pub fn arrayListFromList(vm: *VM, list: List) !std.ArrayList(*MalObject) {
        var result = std.ArrayList(*MalObject).init(vm.allocator);
        var it = list.first;
        while (it) |node| : (it = node.next) {
            try result.append(node.data);
        }
        return result;
    }

    pub fn sliceFromList(vm: *VM, list: List) !Slice {
        return (try vm.arrayListFromList(list)).items;
    }

    pub fn makeVector(vm: *VM, vector: Vector) !*MalObject {
        return vm.make(.{ .vector = .{ .data = vector } });
    }

    pub fn makeVectorEmpty(vm: *VM) !*MalObject {
        return vm.make(.{ .vector = .{ .data = Vector.init(vm.allocator) } });
    }

    pub fn makeVectorCapacity(vm: *VM, num: usize) !*MalObject {
        return vm.make(.{ .vector = .{ .data = try Vector.initCapacity(vm.allocator, num) } });
    }

    pub fn makeVectorFromSlice(vm: *VM, slice: []*MalObject) !*MalObject {
        var vector = try Vector.initCapacity(vm.allocator, slice.len);
        for (slice) |item| {
            vector.appendAssumeCapacity(item);
        }
        return vm.makeVector(vector);
    }

    pub fn makeHashMap(vm: *VM, slice: Slice) !*MalObject {
        var hash_map = HashMap.init(vm.allocator);
        try hash_map.ensureTotalCapacity(@intCast(u32, slice.len / 2));
        var i: usize = 0;
        while (i + 1 < slice.len) : (i += 2) {
            const key = try slice[i].asKey();
            const value = slice[i + 1];
            hash_map.putAssumeCapacity(key, value);
        }
        return vm.make(.{ .hash_map = .{ .data = hash_map } });
    }

    pub fn sliceFromHashMap(vm: *VM, hash_map: HashMap) !Slice {
        var list = try std.ArrayList(*MalObject).initCapacity(vm.allocator, hash_map.count() * 2);
        var it = hash_map.iterator();
        while (it.next()) |entry| {
            list.appendAssumeCapacity(try vm.makeKey(entry.key_ptr.*));
            list.appendAssumeCapacity(entry.value_ptr.*);
        }
        return list.items;
    }

    pub fn makeNil(vm: *VM) !*MalObject {
        return vm.make(.nil);
    }

    pub fn makePrimitive(vm: *VM, primitive: anytype) !*MalObject {
        return vm.make(.{ .primitive = .{ .data = Primitive.make(primitive) } });
    }

    pub fn makeClosure(vm: *VM, closure: Closure) !*MalObject {
        return vm.make(.{ .closure = closure });
    }

    pub fn makeKey(vm: *VM, string: Str) !*MalObject {
        if (string.len > 2 and std.mem.eql(u8, string[0..2], "ʞ")) return vm.makeKeyword(string) else return vm.makeString(string);
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

    pub fn throwMessage(vm: *VM, message: []const u8, err: EvalError) EvalError {
        current_exception = try vm.makeString(message);
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
