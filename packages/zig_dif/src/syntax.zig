//! Lightweight syntax tokenization for diff line rendering.

const std = @import("std");
const zig_treesitter = @import("zig_treesitter");

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
    property_name,
    variable_name,
    constant_name,
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
    if (language == .typescript) {
        if (tokenizeTypeScriptLine(allocator, line)) |tokens| return tokens;
    }
    return tokenizeLineHeuristic(allocator, language, line);
}

fn tokenizeLineHeuristic(
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

const TokenSpan = struct {
    start: usize,
    end: usize,
    kind: TokenKind,
};

fn tokenizeTypeScriptLine(allocator: std.mem.Allocator, line: []const u8) ?[]const Token {
    var parser = zig_treesitter.Parser.init() catch return null;
    defer parser.deinit();
    if (!parser.setLanguage(zig_treesitter.grammars.typescript.language())) return null;

    var tree = parser.parseString(line, null) orelse return null;
    defer tree.deinit();

    var query = zig_treesitter.Query.init(
        zig_treesitter.grammars.typescript.language(),
        zig_treesitter.grammars.typescript.highlights_query,
    ) catch return null;
    defer query.deinit();

    var query_cursor = zig_treesitter.QueryCursor.init() catch return null;
    defer query_cursor.deinit();
    query_cursor.exec(query, tree.rootNode());

    var spans: std.ArrayListUnmanaged(TokenSpan) = .empty;
    defer spans.deinit(allocator);

    while ((query_cursor.nextMatch(allocator) catch return null)) |match| {
        defer match.deinit(allocator);
        for (match.captures) |capture| {
            const capture_name = query.captureName(capture.index) orelse continue;
            const token_kind = classifyTypeScriptCapture(capture_name, capture.node.utf8Text(line));
            if (token_kind == .plain) continue;

            const start = @as(usize, @intCast(capture.node.startByte()));
            const end = @as(usize, @intCast(capture.node.endByte()));
            if (end <= start or start >= line.len) continue;

            spans.append(allocator, .{
                .start = start,
                .end = end,
                .kind = token_kind,
            }) catch return null;
        }
    }

    std.sort.heap(TokenSpan, spans.items, {}, tokenSpanLessThan);

    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    errdefer tokens.deinit(allocator);
    var cursor: usize = 0;

    for (spans.items) |span| {
        if (span.end <= span.start or span.start >= line.len) continue;
        const start = @min(span.start, line.len);
        const end = @min(span.end, line.len);
        if (end <= cursor) continue;
        if (start > cursor) {
            appendToken(&tokens, allocator, .plain, line[cursor..start]) catch return null;
        }
        const effective_start = @max(start, cursor);
        appendToken(&tokens, allocator, span.kind, line[effective_start..end]) catch return null;
        cursor = end;
    }

    if (cursor < line.len) {
        appendToken(&tokens, allocator, .plain, line[cursor..]) catch return null;
    }

    return tokens.toOwnedSlice(allocator) catch null;
}

fn classifyTypeScriptCapture(capture_name: []const u8, text: []const u8) TokenKind {
    if (std.mem.eql(u8, capture_name, "constructor") and !startsUppercase(text)) return .plain;
    if (std.mem.eql(u8, capture_name, "constant") and !looksLikeUpperSnake(text)) return .plain;
    if (std.mem.eql(u8, capture_name, "variable.builtin") and !isTypeScriptBuiltinVariable(text)) return .plain;
    if (std.mem.eql(u8, capture_name, "function.builtin") and !isTypeScriptBuiltinFunction(text)) return .plain;
    if (std.mem.eql(u8, capture_name, "type") and !startsUppercase(text)) return .plain;

    if (std.mem.startsWith(u8, capture_name, "comment")) return .comment;
    if (std.mem.startsWith(u8, capture_name, "string")) return .string;
    if (std.mem.startsWith(u8, capture_name, "constant.numeric") or std.mem.eql(u8, capture_name, "number")) {
        return .number;
    }
    if (std.mem.startsWith(u8, capture_name, "keyword")) return .keyword;
    if (std.mem.startsWith(u8, capture_name, "variable.parameter")) return .variable_name;
    if (std.mem.startsWith(u8, capture_name, "variable.builtin")) return .constant_name;
    if (std.mem.startsWith(u8, capture_name, "variable")) return .variable_name;
    if (std.mem.startsWith(u8, capture_name, "property")) return .property_name;
    if (std.mem.startsWith(u8, capture_name, "constant")) return .constant_name;
    if (std.mem.startsWith(u8, capture_name, "function") or
        std.mem.startsWith(u8, capture_name, "method") or
        std.mem.eql(u8, capture_name, "function.builtin"))
    {
        return .function_name;
    }
    if (std.mem.eql(u8, capture_name, "constructor")) return .type_name;
    if (std.mem.startsWith(u8, capture_name, "type") or std.mem.startsWith(u8, capture_name, "tag")) {
        return .type_name;
    }
    if (std.mem.startsWith(u8, capture_name, "punctuation")) return .punctuation;
    if (std.mem.eql(u8, capture_name, "operator")) return .operator;
    if (text.len == 1 and isPunctuation(text[0])) return .punctuation;
    return .plain;
}

fn tokenSpanLessThan(_: void, left: TokenSpan, right: TokenSpan) bool {
    if (left.start == right.start and left.end == right.end) {
        return tokenKindPriority(left.kind) > tokenKindPriority(right.kind);
    }
    if (left.start == right.start) return left.end > right.end;
    return left.start < right.start;
}

fn tokenKindPriority(kind: TokenKind) u8 {
    return switch (kind) {
        .comment => 11,
        .string => 10,
        .number => 9,
        .keyword => 8,
        .function_name => 7,
        .constant_name => 6,
        .type_name => 5,
        .property_name => 4,
        .variable_name => 3,
        .operator => 2,
        .punctuation => 1,
        .plain => 0,
    };
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

fn looksLikeUpperSnake(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    var saw_upper = false;
    for (identifier) |char| {
        if (std.ascii.isUpper(char)) {
            saw_upper = true;
            continue;
        }
        if (std.ascii.isDigit(char) or char == '_') continue;
        return false;
    }
    return saw_upper;
}

fn isTypeScriptBuiltinVariable(identifier: []const u8) bool {
    return std.mem.eql(u8, identifier, "arguments") or
        std.mem.eql(u8, identifier, "module") or
        std.mem.eql(u8, identifier, "console") or
        std.mem.eql(u8, identifier, "window") or
        std.mem.eql(u8, identifier, "document");
}

fn isTypeScriptBuiltinFunction(identifier: []const u8) bool {
    return std.mem.eql(u8, identifier, "require");
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

fn testTokenKindsContain(tokens: []const Token, kind: TokenKind, text: []const u8) bool {
    for (tokens) |token| {
        if (token.kind == kind and std.mem.eql(u8, token.text, text)) return true;
    }
    return false;
}

test "infer language maps common extensions" {
    try std.testing.expectEqual(Language.typescript, inferLanguage("src/example.ts"));
    try std.testing.expectEqual(Language.tsx, inferLanguage("src/example.tsx"));
    try std.testing.expectEqual(Language.javascript, inferLanguage("src/example.js"));
    try std.testing.expectEqual(Language.json, inferLanguage("data/config.json"));
    try std.testing.expectEqual(Language.markdown, inferLanguage("README.md"));
    try std.testing.expectEqual(Language.plain, inferLanguage("Dockerfile"));
}

test "tokenize json line uses heuristic keywords and numbers" {
    const allocator = std.testing.allocator;
    const line = "{ \"count\": 42, \"active\": true, \"value\": null }";
    const tokens = try tokenizeLine(allocator, .json, line);
    defer allocator.free(tokens);

    try std.testing.expect(testTokenKindsContain(tokens, .string, "\"count\""));
    try std.testing.expect(testTokenKindsContain(tokens, .number, "42"));
    try std.testing.expect(testTokenKindsContain(tokens, .keyword, "true"));
    try std.testing.expect(testTokenKindsContain(tokens, .keyword, "null"));
}

test "tokenize zig line uses heuristic function and type names" {
    const allocator = std.testing.allocator;
    const line = "const Parser = try buildParser(source);";
    const tokens = try tokenizeLine(allocator, .zig, line);
    defer allocator.free(tokens);

    try std.testing.expect(testTokenKindsContain(tokens, .keyword, "const"));
    try std.testing.expect(testTokenKindsContain(tokens, .type_name, "Parser"));
    try std.testing.expect(testTokenKindsContain(tokens, .function_name, "buildParser"));
}

test "tokenize typescript line classifies keywords and strings" {
    const allocator = std.testing.allocator;
    const line = "export const review = async (csvPath: string) => \"ok\";";
    const tokens = try tokenizeLine(allocator, .typescript, line);
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(TokenKind, .keyword), tokens[0].kind);
    try std.testing.expectEqualStrings("export", tokens[0].text);
    try std.testing.expect(testTokenKindsContain(tokens, .keyword, "async"));
    try std.testing.expect(testTokenKindsContain(tokens, .string, "\"ok\""));
    try std.testing.expect(testTokenKindsContain(tokens, .type_name, "string"));
}

test "tokenize typescript line uses tree-sitter highlight captures for functions" {
    const allocator = std.testing.allocator;
    const line = "const result = reviewCampaign(csvPath);";
    const tokens = try tokenizeLine(allocator, .typescript, line);
    defer allocator.free(tokens);

    try std.testing.expect(testTokenKindsContain(tokens, .keyword, "const"));
    try std.testing.expect(testTokenKindsContain(tokens, .function_name, "reviewCampaign"));
    try std.testing.expect(testTokenKindsContain(tokens, .variable_name, "result"));
    try std.testing.expect(testTokenKindsContain(tokens, .variable_name, "csvPath"));
}

test "tokenize typescript line classifies properties and constants" {
    const allocator = std.testing.allocator;
    const line = "const keys = Object.keys(CONSTANT_VALUE);";
    const tokens = try tokenizeLine(allocator, .typescript, line);
    defer allocator.free(tokens);

    try std.testing.expect(testTokenKindsContain(tokens, .type_name, "Object"));
    try std.testing.expect(testTokenKindsContain(tokens, .function_name, "keys"));
    try std.testing.expect(testTokenKindsContain(tokens, .constant_name, "CONSTANT_VALUE"));
}

test "tokenize typescript line classifies builtins punctuation and operators" {
    const allocator = std.testing.allocator;
    const line = "console.log(items?.length ?? 0);";
    const tokens = try tokenizeLine(allocator, .typescript, line);
    defer allocator.free(tokens);

    try std.testing.expect(testTokenKindsContain(tokens, .constant_name, "console"));
    try std.testing.expect(testTokenKindsContain(tokens, .function_name, "log"));
    try std.testing.expect(testTokenKindsContain(tokens, .punctuation, "?."));
    try std.testing.expect(testTokenKindsContain(tokens, .operator, "??"));
    try std.testing.expect(testTokenKindsContain(tokens, .number, "0"));
}
