//! Lightweight syntax tokenization for diff line rendering.

const std = @import("std");

pub const Language = enum {
    plain,
    zig,
    javascript,
    typescript,
    jsx,
    tsx,
    json,
    markdown,
};

pub const TokenKind = enum {
    plain,
    keyword,
    string,
    number,
    comment,
    type_name,
    function_name,
    operator,
    punctuation,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

pub fn inferLanguage(path: []const u8) Language {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(extension, ".ts")) return .typescript;
    if (std.ascii.eqlIgnoreCase(extension, ".tsx")) return .tsx;
    if (std.ascii.eqlIgnoreCase(extension, ".js")) return .javascript;
    if (std.ascii.eqlIgnoreCase(extension, ".jsx")) return .jsx;
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return .json;
    if (std.ascii.eqlIgnoreCase(extension, ".md")) return .markdown;
    return .plain;
}

pub fn tokenizeLine(
    allocator: std.mem.Allocator,
    language: Language,
    line: []const u8,
) std.mem.Allocator.Error![]const Token {
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    var cursor: usize = 0;

    while (cursor < line.len) {
        const char = line[cursor];

        if (std.ascii.isWhitespace(char)) {
            const end = scanWhile(line, cursor, isWhitespaceByte);
            try appendToken(&tokens, allocator, .plain, line[cursor..end]);
            cursor = end;
            continue;
        }

        if (startsLineComment(language, line, cursor)) {
            try appendToken(&tokens, allocator, .comment, line[cursor..]);
            break;
        }

        if (startsBlockComment(language, line, cursor)) {
            const end = scanBlockComment(line, cursor);
            try appendToken(&tokens, allocator, .comment, line[cursor..end]);
            cursor = end;
            continue;
        }

        if (isStringQuote(char)) {
            const end = scanStringLiteral(line, cursor, char);
            try appendToken(&tokens, allocator, .string, line[cursor..end]);
            cursor = end;
            continue;
        }

        if (isNumberStart(line, cursor)) {
            const end = scanNumber(line, cursor);
            try appendToken(&tokens, allocator, .number, line[cursor..end]);
            cursor = end;
            continue;
        }

        if (isIdentifierStart(char)) {
            const end = scanIdentifier(line, cursor);
            const identifier = line[cursor..end];
            const kind = classifyIdentifier(language, line, cursor, end, identifier);
            try appendToken(&tokens, allocator, kind, identifier);
            cursor = end;
            continue;
        }

        const end = cursor + 1;
        const kind: TokenKind = if (isPunctuation(char)) .punctuation else .operator;
        try appendToken(&tokens, allocator, kind, line[cursor..end]);
        cursor = end;
    }

    return tokens.toOwnedSlice(allocator);
}

fn appendToken(
    tokens: *std.ArrayListUnmanaged(Token),
    allocator: std.mem.Allocator,
    kind: TokenKind,
    text: []const u8,
) std.mem.Allocator.Error!void {
    if (text.len == 0) return;
    if (tokens.items.len > 0) {
        const last = &tokens.items[tokens.items.len - 1];
        if (last.kind == kind and last.text.ptr + last.text.len == text.ptr) {
            last.text = last.text.ptr[0 .. last.text.len + text.len];
            return;
        }
    }
    try tokens.append(allocator, .{
        .kind = kind,
        .text = text,
    });
}

fn startsLineComment(language: Language, line: []const u8, cursor: usize) bool {
    return switch (language) {
        .zig, .javascript, .typescript, .jsx, .tsx => std.mem.startsWith(u8, line[cursor..], "//"),
        .markdown => line[cursor] == '#',
        else => false,
    };
}

fn startsBlockComment(language: Language, line: []const u8, cursor: usize) bool {
    return switch (language) {
        .javascript, .typescript, .jsx, .tsx => std.mem.startsWith(u8, line[cursor..], "/*"),
        else => false,
    };
}

fn scanBlockComment(line: []const u8, start: usize) usize {
    const closing = std.mem.indexOfPos(u8, line, start + 2, "*/") orelse return line.len;
    return @min(closing + 2, line.len);
}

fn isStringQuote(char: u8) bool {
    return char == '"' or char == '\'' or char == '`';
}

fn scanStringLiteral(line: []const u8, start: usize, quote: u8) usize {
    var cursor = start + 1;
    while (cursor < line.len) : (cursor += 1) {
        if (line[cursor] == '\\') {
            cursor += 1;
            continue;
        }
        if (line[cursor] == quote) return cursor + 1;
    }
    return line.len;
}

fn isNumberStart(line: []const u8, cursor: usize) bool {
    if (!std.ascii.isDigit(line[cursor])) return false;
    if (cursor == 0) return true;
    return !isIdentifierContinue(line[cursor - 1]);
}

fn scanNumber(line: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < line.len) : (cursor += 1) {
        const char = line[cursor];
        if (std.ascii.isDigit(char) or char == '_' or char == '.' or std.ascii.isAlphabetic(char)) continue;
        break;
    }
    return cursor;
}

fn isIdentifierStart(char: u8) bool {
    return std.ascii.isAlphabetic(char) or char == '_' or char == '$';
}

fn isIdentifierContinue(char: u8) bool {
    return isIdentifierStart(char) or std.ascii.isDigit(char);
}

fn scanIdentifier(line: []const u8, start: usize) usize {
    var cursor = start + 1;
    while (cursor < line.len and isIdentifierContinue(line[cursor])) : (cursor += 1) {}
    return cursor;
}

fn classifyIdentifier(language: Language, line: []const u8, start: usize, end: usize, identifier: []const u8) TokenKind {
    if (isKeyword(language, identifier)) return .keyword;
    if (language == .json and (std.mem.eql(u8, identifier, "true") or std.mem.eql(u8, identifier, "false") or std.mem.eql(u8, identifier, "null"))) {
        return .keyword;
    }
    if (startsUppercase(identifier)) return .type_name;
    if (looksLikeFunctionName(line, start, end)) return .function_name;
    return .plain;
}

fn looksLikeFunctionName(line: []const u8, start: usize, end: usize) bool {
    _ = start;
    var cursor = end;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    return cursor < line.len and line[cursor] == '(';
}

fn startsUppercase(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    return std.ascii.isUpper(identifier[0]);
}

fn isKeyword(language: Language, identifier: []const u8) bool {
    const keywords = switch (language) {
        .zig => zig_keywords[0..],
        .javascript, .jsx => js_keywords[0..],
        .typescript, .tsx => ts_keywords[0..],
        .json, .markdown, .plain => return false,
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, identifier)) return true;
    }
    return false;
}

fn isWhitespaceByte(char: u8) bool {
    return std.ascii.isWhitespace(char);
}

fn scanWhile(line: []const u8, start: usize, comptime predicate: fn (u8) bool) usize {
    var cursor = start;
    while (cursor < line.len and predicate(line[cursor])) : (cursor += 1) {}
    return cursor;
}

fn isPunctuation(char: u8) bool {
    return switch (char) {
        '(', ')', '[', ']', '{', '}', ',', ';', ':' => true,
        else => false,
    };
}

const zig_keywords = [_][]const u8{
    "addrspace",   "align",       "allowzero",      "and",      "anyframe", "anytype",  "asm",         "async",  "await",
    "break",       "callconv",    "catch",          "comptime", "const",    "continue", "defer",       "else",   "enum",
    "errdefer",    "error",       "export",         "extern",   "false",    "fn",       "for",         "if",     "inline",
    "linksection", "noalias",     "nosuspend",      "null",     "opaque",   "or",       "orelse",      "packed", "pub",
    "resume",      "return",      "struct",         "suspend",  "switch",   "test",     "threadlocal", "true",   "try",
    "union",       "unreachable", "usingnamespace", "var",      "volatile", "while",
};

const js_keywords = [_][]const u8{
    "as",      "async",  "await", "break",      "case",   "catch",   "class",   "const",  "continue", "debugger",
    "default", "delete", "do",    "else",       "export", "extends", "finally", "for",    "from",     "function",
    "if",      "import", "in",    "instanceof", "let",    "new",     "of",      "return", "static",   "super",
    "switch",  "this",   "throw", "try",        "typeof", "var",     "void",    "while",  "with",     "yield",
};

const ts_keywords = [_][]const u8{
    "abstract", "as",      "async",     "await",     "break",      "case",   "catch",    "class",   "const",      "continue",
    "debugger", "declare", "default",   "delete",    "do",         "else",   "enum",     "export",  "extends",    "finally",
    "for",      "from",    "function",  "if",        "implements", "import", "in",       "infer",   "instanceof", "interface",
    "is",       "keyof",   "let",       "namespace", "new",        "of",     "override", "private", "protected",  "public",
    "readonly", "return",  "satisfies", "static",    "super",      "switch", "this",     "throw",   "try",        "type",
    "typeof",   "using",   "var",       "void",      "while",      "with",   "yield",
};

test "tokenize typescript line classifies keywords and strings" {
    const allocator = std.testing.allocator;
    const line = "export const review = async (csvPath: string) => \"ok\";";
    const tokens = try tokenizeLine(allocator, .typescript, line);
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(TokenKind, .keyword), tokens[0].kind);
    try std.testing.expectEqualStrings("export", tokens[0].text);
    try std.testing.expectEqual(@as(TokenKind, .string), tokens[tokens.len - 2].kind);
}
