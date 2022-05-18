const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("./core.zig");
const Env = @import("./env.zig").Env;
const printer = @import("./printer.zig");
const reader = @import("./reader.zig");
const types = @import("./types.zig");
const EvalError = types.EvalError;
const MalType = types.MalType;

const input_buffer_length = 256;
const prompt = "user> ";

fn READ(allocator: Allocator, input: []const u8) !*MalType {
    return reader.read_str(allocator, input);
}

fn EVAL(allocator: Allocator, ast: *MalType, env: *Env) EvalError!*MalType {
    var current_ast = ast;
    var current_env = env;
    while (true) {
        // expand macros
        current_ast = try macroexpand(allocator, current_ast, env);

        switch (current_ast.*) {
            .list => |list| {
                const list_items = try MalType.sliceFromList(allocator, list);
                if (list_items.len == 0) return MalType.makeListEmpty(allocator) else {
                    // apply phase
                    const first = list_items[0];
                    if (first.* == .symbol) {
                        if (first.isSymbol("def!")) {
                            const rest = list_items[1..];
                            if (rest.len != 2) return error.EvalDefInvalidOperands;
                            const key_symbol = rest[0].asSymbol() catch return error.EvalDefInvalidOperands;

                            const evaled_value = try EVAL(allocator, rest[1], current_env);
                            try current_env.set(key_symbol, evaled_value);
                            return evaled_value;
                        }

                        if (first.isSymbol("let*")) {
                            const rest = list_items[1..];
                            if (rest.len != 2) return error.EvalLetInvalidOperands;
                            const bindings = rest[0].toSlice(allocator) catch return error.EvalLetInvalidOperands;
                            if (@mod(bindings.len, 2) != 0) return error.EvalLetInvalidOperands;

                            var let_env = try current_env.initChild();
                            var i: usize = 0;
                            while (i < bindings.len) : (i += 2) {
                                const current_bindings = bindings[i .. i + 2];
                                const key_symbol = current_bindings[0].asSymbol() catch return error.EvalDefInvalidOperands;
                                const evaled_value = try EVAL(allocator, current_bindings[1], let_env);
                                try let_env.set(key_symbol, evaled_value);
                            }
                            current_ast = rest[1];
                            current_env = let_env;
                            continue;
                        }

                        if (first.isSymbol("if")) {
                            const rest = list_items[1..];
                            if (rest.len != 2 and rest.len != 3) return error.EvalIfInvalidOperands;
                            const condition = rest[0];
                            const evaled_value = try EVAL(allocator, condition, current_env);
                            if (evaled_value.isTruthy())
                                current_ast = rest[1]
                            else if (rest.len == 3)
                                current_ast = rest[2]
                            else
                                current_ast = try MalType.makeNil(allocator);
                            continue;
                        }

                        if (first.isSymbol("do")) {
                            const do_len = list_items.len - 1;
                            if (do_len < 1) return error.EvalDoInvalidOperands;
                            const do_ast = try MalType.makeList(allocator, list_items[1..do_len]);
                            _ = try eval_ast(allocator, do_ast, current_env);
                            current_ast = list_items[do_len];
                            continue;
                        }

                        if (first.isSymbol("fn*")) {
                            const parameters = list_items[1].toSlice(allocator) catch return error.EvalInvalidFnParamsList;
                            // convert from a list of MalType to a list of valid symbol keys to use in environment init
                            var binds = try std.ArrayList(MalType.Symbol).initCapacity(allocator, parameters.len);
                            for (parameters) |parameter| {
                                const parameter_symbol = parameter.asSymbol() catch return error.EvalInvalidFnParamsList;
                                binds.appendAssumeCapacity(parameter_symbol);
                            }
                            return MalType.makeClosure(allocator, .{
                                .parameters = binds,
                                .body = list_items[2],
                                .env = current_env,
                                .eval = EVAL,
                            });
                        }

                        if (first.isSymbol("quote")) {
                            const rest = list_items[1..];
                            if (rest.len != 1) return error.EvalQuoteInvalidOperands;
                            return list_items[1];
                        }

                        if (first.isSymbol("quasiquoteexpand")) {
                            const rest = list_items[1..];
                            if (rest.len != 1) return error.EvalQuasiquoteexpandInvalidOperands;
                            return quasiquote(allocator, list_items[1]);
                        }

                        if (first.isSymbol("quasiquote")) {
                            const rest = list_items[1..];
                            if (rest.len != 1) return error.EvalQuasiquoteInvalidOperands;
                            current_ast = try quasiquote(allocator, list_items[1]);
                            continue;
                        }

                        if (first.isSymbol("defmacro!")) {
                            const rest = list_items[1..];
                            if (rest.len != 2) return error.EvalDefmacroInvalidOperands;
                            const key_symbol = rest[0].asSymbol() catch return error.EvalDefmacroInvalidOperands;

                            const evaled_value = try EVAL(allocator, rest[1], current_env);
                            // make a copy to avoid mutating existing functions
                            var macro = try MalType.make(allocator, evaled_value.*);
                            macro.closure.is_macro = true;
                            try current_env.set(key_symbol, macro);
                            return macro;
                        }

                        if (first.isSymbol("macroexpand")) {
                            const rest = list_items[1..];
                            if (rest.len != 1) return error.EvalMacroexpandInvalidOperands;
                            return macroexpand(allocator, list_items[1], env);
                        }

                        if (first.isSymbol("try*")) {
                            const rest = list_items[1..];
                            if (rest.len != 2) return error.EvalTryInvalidOperands;
                            return EVAL(allocator, rest[0], env) catch {
                                const catch_list = try rest[1].asList();
                                const catch_list_items = try MalType.sliceFromList(allocator, catch_list);
                                if (catch_list_items.len != 3) return error.EvalCatchInvalidOperands;
                                if (!catch_list_items[0].isSymbol("catch*")) return error.EvalTryNoCatch;
                                const catch_symbol = try catch_list_items[1].asSymbol();
                                var catch_env = try current_env.initChild();
                                try catch_env.set(catch_symbol, types.current_exception orelse try MalType.makeNil(allocator));
                                const result = try EVAL(allocator, catch_list_items[2], catch_env);
                                // reset global exception if it has been handled
                                types.current_exception = null;
                                return result;
                            };
                        }

                        // if (first.isSymbol("catch*")) {
                        //     TODO: do something here?
                        // }
                    }
                    const evaled_ast = try eval_ast(allocator, current_ast, current_env);
                    const evaled_items = try evaled_ast.toSlice(allocator);

                    const function = evaled_items[0];
                    const args = evaled_items[1..];

                    switch (function.*) {
                        .primitive => |primitive| return primitive.apply(allocator, args),
                        .closure => |closure| {
                            const parameters = closure.parameters.items;
                            // if (parameters.len != args.len) {
                            //     return error.EvalInvalidOperands;
                            // }
                            var fn_env = try closure.env.initChildBindExprs(parameters, args);
                            current_ast = closure.body;
                            current_env = fn_env;
                            continue;
                        },
                        else => return error.EvalNotSymbolOrFn,
                    }
                }
            },
            else => return eval_ast(allocator, current_ast, current_env),
        }
    }
}

fn eval_ast(allocator: Allocator, ast: *MalType, env: *Env) EvalError!*MalType {
    switch (ast.*) {
        .symbol => |symbol| return env.get(symbol) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "'{s}' not found", .{symbol});
            types.current_exception = try MalType.makeString(allocator, message);
            return err;
        },
        .list => |list| {
            var results = try std.ArrayList(*MalType).initCapacity(allocator, list.len());
            var it = list.first;
            while (it) |node| : (it = node.next) {
                const result = try EVAL(allocator, node.data, env);
                results.appendAssumeCapacity(result);
            }
            return MalType.makeList(allocator, results.items);
        },
        .vector => |vector| {
            var results = try std.ArrayList(*MalType).initCapacity(allocator, vector.items.len);
            for (vector.items) |item| {
                const result = try EVAL(allocator, item, env);
                results.appendAssumeCapacity(result);
            }
            return MalType.makeVector(allocator, results);
        },
        .hash_map => |hash_map| {
            var results = try std.ArrayList(*MalType).initCapacity(allocator, 2 * hash_map.count());
            var it = hash_map.iterator();
            while (it.next()) |entry| {
                results.appendAssumeCapacity(try MalType.makeKey(allocator, entry.key_ptr.*));
                const result = try EVAL(allocator, entry.value_ptr.*, env);
                results.appendAssumeCapacity(result);
            }
            return MalType.makeHashMap(allocator, results.items);
        },
        else => return ast,
    }
}

fn PRINT(allocator: Allocator, ast: *const MalType) ![]const u8 {
    const output = try printer.pr_str(allocator, ast, true);
    return output;
}

fn rep(global_allocator: Allocator, allocator: Allocator, input: []const u8, env: *Env) ![]const u8 {
    const ast = try READ(global_allocator, input);
    const result = try EVAL(global_allocator, ast, env);
    const output = try PRINT(allocator, result);
    return output;
}

var repl_env: Env = undefined;

fn eval(allocator: Allocator, ast: *MalType) EvalError!*MalType {
    return EVAL(allocator, ast, &repl_env);
}

fn quasiquote(allocator: Allocator, ast: *MalType) EvalError!*MalType {
    switch (ast.*) {
        .list => |list| {
            const list_items = try MalType.sliceFromList(allocator, list);
            if (list_items[0].isSymbol("unquote")) {
                return list_items[1];
            }
            var result = try MalType.makeListEmpty(allocator);
            var i = list_items.len;
            while (i > 0) {
                i -= 1;
                const element = list_items[i];
                if (element.* == .list and element.list.first.?.data.isSymbol("splice-unquote")) {
                    const concat = try MalType.makeSymbol(allocator, "concat");
                    result = try MalType.makeList(allocator, &.{ concat, element.list.first.?.next.?.data, result });
                } else {
                    const cons = try MalType.makeSymbol(allocator, "cons");
                    result = try MalType.makeList(allocator, &.{ cons, try quasiquote(allocator, element), result });
                }
            }
            return result;
        },
        .vector => |vector| {
            var result = try MalType.makeListEmpty(allocator);
            var i = vector.items.len;
            while (i > 0) {
                i -= 1;
                const element = vector.items[i];
                if (element.* == .list and element.list.first.?.data.isSymbol("splice-unquote")) {
                    const concat = try MalType.makeSymbol(allocator, "concat");
                    result = try MalType.makeList(allocator, &.{ concat, element.list.first.?.next.?.data, result });
                } else {
                    const cons = try MalType.makeSymbol(allocator, "cons");
                    result = try MalType.makeList(allocator, &.{ cons, try quasiquote(allocator, element), result });
                }
            }
            return result;
        },
        .symbol => {
            const quote = try MalType.makeSymbol(allocator, "quote");
            return MalType.makeList(allocator, &.{ quote, ast });
        },
        else => return ast,
    }
}

fn is_macro_call(ast: *MalType, env: *Env) bool {
    if (ast.* == .list and ast.list.first != null and ast.list.first.?.data.* == .symbol) {
        const symbol = ast.list.first.?.data.symbol;
        if (env.get(symbol)) |value| {
            return value.* == .closure and value.closure.is_macro;
        } else |_| {}
    }
    return false;
}

fn macroexpand(allocator: Allocator, ast: *MalType, env: *Env) !*MalType {
    var current_ast = ast;
    while (is_macro_call(current_ast, env)) {
        const macro = try env.get(current_ast.list.first.?.data.symbol);
        current_ast = try macro.apply(allocator, (try current_ast.toSlice(allocator))[1..]);
    }
    return current_ast;
}

pub fn main() anyerror!void {
    // general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // global arena allocator
    var global_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer global_arena.deinit();
    const gaa = global_arena.allocator();

    // REPL environment
    repl_env = Env.init(gpa.allocator(), null);
    defer repl_env.deinit();

    inline for (@typeInfo(@TypeOf(core.ns)).Struct.fields) |field| {
        try repl_env.set(field.name, try MalType.makePrimitive(gaa, @field(core.ns, field.name)));
    }

    try repl_env.set("eval", try MalType.makePrimitive(gaa, eval));

    var input_buffer: [input_buffer_length]u8 = undefined;
    // initialize std io reader and writer
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // evaluate global prelude/preamble-type expressions
    _ = try rep(gaa, gaa, "(def! not (fn* (a) (if a false true)))", &repl_env);
    _ = try rep(gaa, gaa, "(def! load-file (fn* (f) (eval (read-string (str \"(do \" (slurp f) \"\nnil)\")))))", &repl_env);
    _ = try rep(gaa, gaa, "(defmacro! cond (fn* (& xs) (if (> (count xs) 0) (list 'if (first xs) (if (> (count xs) 1) (nth xs 1) (throw \"odd number of forms to cond\")) (cons 'cond (rest (rest xs)))))))", &repl_env);

    // read command line arguments
    var iter = std.process.args();
    // ignore first argument (executable file)
    _ = iter.skip();

    // read second argument as file to load
    const opt_filename = iter.next();

    // read rest of CLI arguments into the *ARGV* list
    var argv = std.ArrayList(*MalType).init(gaa);
    while (iter.next()) |arg| {
        try argv.append(try MalType.makeString(gaa, arg));
    }
    try repl_env.set("*ARGV*", try MalType.makeList(gaa, argv.items));

    const host_language = "mal-zig";
    try repl_env.set("*host-language*", try MalType.makeString(gaa, host_language));

    // call (load-file filename) if given a filename argument
    if (opt_filename) |filename| {
        const string = try std.mem.join(gaa, "\"", &.{ "(load-file ", filename, ")" });
        _ = try rep(gaa, gaa, string, &repl_env);
        return;
    }

    _ = try rep(gaa, gaa, "(println (str \"Mal [\" *host-language* \"]\"))", &repl_env);

    // main repl loop
    while (true) {
        // print prompt
        // TODO: line editing and history, (readline, editline, linenoise)
        try stdout.print(prompt, .{});
        // read line of input
        const line = (try stdin.readUntilDelimiterOrEof(&input_buffer, '\n')) orelse {
            // reached input end-of-file
            break;
        };
        // local arena allocator, memory is freed at end of loop iteration
        var arena = std.heap.ArenaAllocator.init(gpa.allocator());
        defer arena.deinit();

        // read-eval-print
        if (rep(gaa, arena.allocator(), line, &repl_env)) |result|
            try stdout.print("{s}\n", .{result})
        else |err| {
            const message = if (types.current_exception) |exception| blk: {
                const exception_message = exception.asString() catch printer.pr_str(arena.allocator(), exception, true);
                break :blk exception_message;
            } else switch (err) {
                error.EmptyInput => continue,
                error.EndOfInput => "unexpected end of input",
                error.ListNoClosingTag => "unbalanced list form, missing closing ')'",
                error.StringLiteralNoClosingTag => "unbalanced string literal, missing closing '\"'",
                error.TokensPastFormEnd => "found additional tokens past end of form",
                error.EvalDefInvalidOperands => "Invalid def! operands",
                error.EvalDoInvalidOperands => "Invalid do operands",
                error.EvalIfInvalidOperands => "Invalid if operands",
                error.EvalLetInvalidOperands => "Invalid let* operands",
                error.EvalQuoteInvalidOperands => "Invalid quote operands",
                error.EvalQuasiquoteInvalidOperands => "Invalid quasiquote operands",
                error.EvalQuasiquoteexpandInvalidOperands => "Invalid quasiquoteexpand operands",
                error.EvalDefmacroInvalidOperands => "Invalid defmacro! operands",
                error.EvalMacroexpandInvalidOperands => "Invalid expandmacro operands",
                error.EvalConsInvalidOperands => "Invalid cons operands",
                error.EvalConcatInvalidOperands => "Invalid concat operands",
                error.EvalVecInvalidOperands => "Invalid vec operands",
                error.EvalNthInvalidOperands => "Invalid nth operands",
                error.EvalFirstInvalidOperands => "Invalid first operands",
                error.EvalRestInvalidOperands => "Invalid rest operands",
                error.EvalApplyInvalidOperands => "Invalid apply operands",
                error.EvalMapInvalidOperands => "Invalid map operands",
                error.EvalConjInvalidOperands => "Invalid conj operands",
                error.EvalSeqInvalidOperands => "Invalid seq operands",
                error.EvalInvalidFnParamsList => "Invalid parameter list to fn* expression",
                error.EvalInvalidOperand => "Invalid operand",
                error.EvalInvalidOperands => "Invalid operands, wrong function argument arity",
                error.EvalNotSymbolOrFn => "tried to evaluate list where the first item is not a function or special form",
                error.EvalIndexOutOfRange => "index out of range",
                error.EvalTryNoCatch => "try* without associated catch*",
                error.EnvSymbolNotFound => "symbol not found",
                error.NotImplemented => "function not implemented",
                error.OutOfMemory => "out of memory",
                else => @errorName(err),
            };
            try stderr.print("Error: {s}\n", .{message});
            // print error return stack trace in debug build
            // if (@errorReturnTrace()) |trace| {
            //     std.debug.dumpStackTrace(trace.*);
            // }
            types.current_exception = null;
        }
    }
}
