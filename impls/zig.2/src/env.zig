const std = @import("std");

const types = @import("./types.zig");
const MalObject = types.MalObject;
const VM = types.VM;

pub const Data = std.StringHashMap(*MalObject);

pub const Env = struct {
    outer: ?*const Env,
    data: Data,
    vm: *VM,

    pub fn init(vm: *VM, outer: ?*const Env) Env {
        return .{
            .outer = outer,
            .data = Data.init(vm.allocator),
            .vm = vm,
        };
    }

    pub fn initCapacity(vm: *VM, outer: ?*const Env, size: u32) !Env {
        var self = Env.init(vm, outer);
        try self.data.ensureTotalCapacity(size);
        return self;
    }

    pub fn initBindExprs(vm: *VM, outer: ?*const Env, binds: []const []const u8, exprs: []*MalObject) !Env {
        // std.debug.assert(binds.len == exprs.len);
        var self = try Env.initCapacity(vm, outer, @intCast(u32, binds.len));
        for (binds) |symbol, i| {
            if (std.mem.eql(u8, symbol, "&")) {
                const rest_symbol = binds[i + 1];
                try self.set(rest_symbol, try vm.makeList(exprs[i..]));
                break;
            }
            try self.set(symbol, exprs[i]);
        }
        return self;
    }

    pub fn deinit(self: *Env) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            // free copied hash map keys
            self.data.allocator.free(entry.key_ptr.*);
        }
        self.data.deinit();
        self.* = undefined;
    }

    pub fn initChild(self: *Env) !*Env {
        var child_ptr = try self.vm.allocator.create(Env);
        child_ptr.* = Env.init(self.vm, self);
        return child_ptr;
    }

    pub fn initChildBindExprs(self: *Env, binds: []const []const u8, exprs: []*MalObject) !*Env {
        var child_ptr = try self.vm.allocator.create(Env);
        child_ptr.* = try Env.initBindExprs(self.vm, self, binds, exprs);
        return child_ptr;
    }

    pub fn set(self: *Env, symbol: []const u8, value: *MalObject) !void {
        const allocator = self.data.allocator;

        const get_or_put = try self.data.getOrPut(symbol);
        if (get_or_put.found_existing) {
            // get_or_put.value_ptr.*.deinit();
        } else {
            // copy the symbol to use as key with the same lifetime as the hash map
            get_or_put.key_ptr.* = allocator.dupe(u8, symbol) catch |err| {
                _ = self.data.remove(symbol);
                return err;
            };
        }
        get_or_put.value_ptr.* = value;
    }

    pub fn find(self: *const Env, symbol: []const u8) ?*const Env {
        return if (self.data.contains(symbol))
            self
        else if (self.outer) |outer| outer.find(symbol) else null;
    }

    pub fn get(self: Env, symbol: []const u8) !*MalObject {
        return if (self.find(symbol)) |env|
            env.data.get(symbol) orelse unreachable
        else
            error.EnvSymbolNotFound;
    }
};
