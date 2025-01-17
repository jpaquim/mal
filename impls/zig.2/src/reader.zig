const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("./types.zig");
const MalType = types.MalType;
const replaceMultipleOwned = @import("./utils.zig").replaceMultipleOwned;

const Token = []const u8;
const TokenList = std.ArrayList(Token);

const Reader = struct {
    const Self = @This();

    tokens: TokenList,
    position: u16,

    pub fn init(tokens: TokenList) Self {
        return Self{
            .tokens = tokens,
            .position = 0,
        };
    }

    pub fn next(self: *Self) ?Token {
        if (self.position >= self.tokens.items.len) {
            return null;
        }
        const token = self.tokens.items[self.position];
        self.position += 1;
        return token;
    }

    pub fn peek(self: *Self) ?Token {
        if (self.position >= self.tokens.items.len) {
            return null;
        }
        return self.tokens.items[self.position];
    }
};

pub const ReadError = error{
    EmptyInput,
    EndOfInput,
    ListNoClosingTag,
    NotKey,
    StringLiteralNoClosingTag,
    TokensPastFormEnd,
} || Allocator.Error;

pub fn read_str(allocator: Allocator, input: []const u8) !*MalType {
    // tokenize input string into token list
    const tokens = try tokenize(allocator, input);
    // check if there are no tokens in which case we throw a special error to
    // continue the main REPL loop
    if (tokens.items.len == 0 or tokens.items.len == 1 and tokens.items[0][0] == ';') {
        return error.EmptyInput;
    }

    // create a Reader instance with the tokens list
    var reader = Reader.init(tokens);
    // read a mal form
    const form = (try read_form(allocator, &reader)) orelse return error.EndOfInput;
    // check if there are still remaining tokens after the form is read
    if (reader.peek()) |token| blk: {
        // check if the token is a comment, in which case there is no error
        if (token[0] == ';') {
            break :blk;
        }
        // there should only be a single top-level form, so any remaining token
        // indicates an error
        return error.TokensPastFormEnd;
    }
    return form;
}

fn readerMacro(allocator: Allocator, reader: *Reader, symbol: []const u8) !*MalType {
    const prefix = try MalType.makeSymbol(allocator, symbol);
    const form = (try read_form(allocator, reader)) orelse return error.EndOfInput;
    return MalType.makeList(allocator, &.{ prefix, form });
}

fn read_form(allocator: Allocator, reader: *Reader) ReadError!?*MalType {
    while (true) {
        if (reader.peek()) |token|
            switch (token[0]) {
                '(' => return read_list(allocator, reader, .list),
                '[' => return read_list(allocator, reader, .vector),
                '{' => return read_list(allocator, reader, .hash_map),
                ')', ']', '}' => return null,
                // skip over comment tokens
                ';' => {
                    _ = reader.next();
                    continue;
                },
                // reader macros:
                // @form => (deref form)
                '@' => {
                    _ = reader.next();
                    return readerMacro(allocator, reader, "deref");
                },
                // 'form => (quote form)
                '\'' => {
                    _ = reader.next();
                    return readerMacro(allocator, reader, "quote");
                },
                // `form => (quasiquote form)
                '`' => {
                    _ = reader.next();
                    return readerMacro(allocator, reader, "quasiquote");
                },
                // ~form => (unquote form)
                // ~@form => (splice-unquote form)
                '~' => {
                    _ = reader.next();
                    if (std.mem.eql(u8, token, "~@")) {
                        return readerMacro(allocator, reader, "splice-unquote");
                    }
                    return readerMacro(allocator, reader, "unquote");
                },
                // ^metadata form => (with-meta form metadata)
                '^' => {
                    _ = reader.next();
                    const prefix = try MalType.makeSymbol(allocator, "with-meta");
                    const metadata_form = (try read_form(allocator, reader)) orelse return error.EndOfInput;
                    const form = (try read_form(allocator, reader)) orelse return error.EndOfInput;
                    return MalType.makeList(allocator, &.{ prefix, form, metadata_form });
                },
                else => return read_atom(allocator, reader),
            }
        else
            return error.EndOfInput;
    }
}

const ListType = enum {
    list,
    vector,
    hash_map,
};

fn read_list(allocator: Allocator, reader: *Reader, list_type: ListType) !*MalType {
    // skip over the first '(', '[', '{' token in the list
    _ = reader.next();
    var list = std.ArrayList(*MalType).init(allocator);
    // read the next forms until a matching ')', ']', '}' is found, or error otherwise
    var err_form = read_form(allocator, reader);
    while (err_form) |opt_form| : (err_form = read_form(allocator, reader)) {
        if (opt_form) |form| {
            // push valid forms into array list
            try list.append(form);
        } else {
            // found matching ')', ']', '}' break loop
            break;
        }
        // no matching closing ')', ']', '}' parenthes, return error
    } else |_| return error.ListNoClosingTag;
    // skip over the last ')', ']', '}' token in the list
    _ = reader.next();
    switch (list_type) {
        .list => return MalType.makeList(allocator, list.items),
        .vector => return MalType.makeVector(allocator, list),
        .hash_map => return MalType.makeHashMap(allocator, list.items),
    }
}

fn read_atom(allocator: Allocator, reader: *Reader) !*MalType {
    const result = if (reader.next()) |token|
        if (std.mem.eql(u8, token, "nil"))
            .nil
        else if (std.mem.eql(u8, token, "true"))
            .t
        else if (std.mem.eql(u8, token, "false"))
            .f
        else if (token[0] == '"') MalType{
            .string = try replaceEscapeSequences(allocator, token[1 .. token.len - 1]),
        } else if (token[0] == ':') MalType{
            .keyword = try MalType.addKeywordPrefix(allocator, token[1..]),
        } else if (std.fmt.parseInt(i64, token, 10)) |int| MalType{
            .number = int,
        } else |_| MalType{
            .symbol = try allocator.dupe(u8, token),
        }
    else
        return error.EndOfInput;
    return MalType.make(allocator, result);
}

fn replaceEscapeSequences(allocator: Allocator, str: []const u8) ![]const u8 {
    // replace \" with "
    // replace \\ with \
    // replace \n with newline character
    const needles = .{ "\\\"", "\\\\", "\\n" };
    const replacements = .{ "\"", "\\", "\n" };
    return replaceMultipleOwned(u8, 3, allocator, str, needles, replacements);
}

// [\s,]*(~@|[\[\]{}()'`~^@]|"(?:\\.|[^\\"])*"?|;.*|[^\s\[\]{}('"`,;)]*)

// For each match captured within the parenthesis starting at char 6 of the regular expression a
// new token will be created.

// [\s,]*: Matches any number of whitespaces or commas. This is not captured so it will be
// ignored and not tokenized.

// ~@: Captures the special two-characters ~@ (tokenized).

// [\[\]{}()'`~^@]: Captures any special single character, one of []{}()'`~^@ (tokenized).

// "(?:\\.|[^\\"])*"?: Starts capturing at a double-quote and stops at the next double-quote
// unless it was preceded by a backslash in which case it includes it until the next
// double-quote (tokenized). It will also match unbalanced strings (no ending double-quote)
// which should be reported as an error.

// ;.*: Captures any sequence of characters starting with ; (tokenized).

// [^\s\[\]{}('"`,;)]*: Captures a sequence of zero or more non special characters (e.g.
// symbols, numbers, "true", "false", and "nil") and is sort of the inverse of the one above
// that captures special characters (tokenized).
fn tokenize(allocator: Allocator, input: []const u8) !TokenList {
    var tokens = TokenList.init(allocator);

    const State = enum {
        start,
        comment,
        other,
        string_literal,
        string_literal_backslash,
        tilde,
    };
    var state: State = .start;
    var start_index: usize = undefined;

    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const c = input[index];
        switch (state) {
            .start => switch (c) {
                ' ', '\n', '\t', '\r', ',' => {},
                '"' => {
                    state = .string_literal;
                    start_index = index;
                },
                '~' => {
                    state = .tilde;
                    start_index = index;
                },
                '[', ']', '{', '}', '(', ')', '\'', '`', '^', '@' => {
                    try tokens.append(input[index .. index + 1]);
                },
                ';' => {
                    state = .comment;
                    start_index = index;
                },
                else => {
                    state = .other;
                    start_index = index;
                },
            },
            .tilde => switch (c) {
                '@' => {
                    try tokens.append("~@");
                    state = .start;
                    start_index = undefined;
                },
                else => {
                    try tokens.append("~");
                    // backtrack with .start state
                    index -= 1;
                    state = .start;
                    start_index = undefined;
                },
            },
            .string_literal => switch (c) {
                '"' => {
                    try tokens.append(input[start_index .. index + 1]);
                    state = .start;
                    start_index = undefined;
                },
                '\\' => {
                    state = .string_literal_backslash;
                },
                else => {},
            },
            .string_literal_backslash => switch (c) {
                '"' => {
                    state = .string_literal;
                },
                else => {
                    state = .string_literal;
                },
            },
            .comment => switch (c) {
                '\n' => {
                    try tokens.append(input[start_index..index]);
                    state = .start;
                    start_index = undefined;
                },
                else => {},
            },
            .other => switch (c) {
                ' ', '\n', '\t', '\r', ',', '"', '~', '[', ']', '{', '}', '(', ')', '\'', '`', '^', ';' => {
                    try tokens.append(input[start_index..index]);
                    // backtrack with .start state
                    index -= 1;
                    state = .start;
                    start_index = undefined;
                },
                else => {},
            },
        }
    }
    switch (state) {
        .start => {},
        .comment, .other, .tilde => {
            try tokens.append(input[start_index..index]);
        },
        .string_literal, .string_literal_backslash => {
            return error.StringLiteralNoClosingTag;
        },
    }
    return tokens;
}
