/// File icons for FFF file search
const std = @import("std");

const colors = @import("colors.zig");

pub const FileIcon = struct {
    glyph: []const u8,
    color: [4]f32,
};

pub const folder = FileIcon{ .glyph = "\u{ea83}", .color = colors.rgb(0xE6, 0xC0, 0x68) };

const generic_file = FileIcon{ .glyph = "\u{ea7b}", .color = colors.rgb(0xB0, 0xBC, 0xC8) };
const generic_code_file = FileIcon{ .glyph = "\u{eac4}", .color = colors.rgb(0x7D, 0xC4, 0xE4) };
const astro_file = FileIcon{ .glyph = "", .color = colors.rgb(0xE2, 0x3F, 0x67) };
const bash_file = FileIcon{ .glyph = "", .color = colors.rgb(0x89, 0xE0, 0x51) };
const c_file = FileIcon{ .glyph = "", .color = colors.rgb(0x59, 0x9E, 0xFF) };
const c_header_file = FileIcon{ .glyph = "", .color = colors.rgb(0xA0, 0x74, 0xC4) };
const cpp_file = FileIcon{ .glyph = "", .color = colors.rgb(0x51, 0x9A, 0xBA) };
const css_file = FileIcon{ .glyph = "", .color = colors.rgb(0x66, 0x33, 0x99) };
const go_file = FileIcon{ .glyph = "", .color = colors.rgb(0x00, 0xAD, 0xD8) };
const graphql_file = FileIcon{ .glyph = "", .color = colors.rgb(0xE5, 0x35, 0xAB) };
const html_file = FileIcon{ .glyph = "", .color = colors.rgb(0xE4, 0x4D, 0x26) };
const java_file = FileIcon{ .glyph = "", .color = colors.rgb(0xCC, 0x3E, 0x44) };
const javascript_file = FileIcon{ .glyph = "", .color = colors.rgb(0xCB, 0xCB, 0x41) };
const json_file = FileIcon{ .glyph = "", .color = colors.rgb(0xCB, 0xCB, 0x41) };
const jsx_file = FileIcon{ .glyph = "", .color = colors.rgb(0x20, 0xC2, 0xE3) };
const kotlin_file = FileIcon{ .glyph = "", .color = colors.rgb(0x7F, 0x52, 0xFF) };
const less_file = FileIcon{ .glyph = "", .color = colors.rgb(0x56, 0x3D, 0x7C) };
const lua_file = FileIcon{ .glyph = "", .color = colors.rgb(0x51, 0xA0, 0xCF) };
const markdown_file = FileIcon{ .glyph = "", .color = colors.rgb(0xED, 0xED, 0xED) };
const media_file = FileIcon{ .glyph = "\u{eaea}", .color = colors.rgb(0xD6, 0x96, 0xF2) };
const pdf_file = FileIcon{ .glyph = "\u{eaeb}", .color = colors.rgb(0xF2, 0x71, 0x71) };
const php_file = FileIcon{ .glyph = "", .color = colors.rgb(0xA0, 0x74, 0xC4) };
const python_file = FileIcon{ .glyph = "", .color = colors.rgb(0xFF, 0xBC, 0x03) };
const ruby_file = FileIcon{ .glyph = "", .color = colors.rgb(0x70, 0x15, 0x16) };
const rust_file = FileIcon{ .glyph = "", .color = colors.rgb(0xDE, 0xA5, 0x84) };
const sass_file = FileIcon{ .glyph = "", .color = colors.rgb(0xF5, 0x53, 0x85) };
const sql_file = FileIcon{ .glyph = "", .color = colors.rgb(0xDA, 0xD8, 0xD8) };
const svelte_file = FileIcon{ .glyph = "", .color = colors.rgb(0xFF, 0x3E, 0x00) };
const shell_file = FileIcon{ .glyph = "", .color = colors.rgb(0x4D, 0x5A, 0x5E) };
const binary_file = FileIcon{ .glyph = "\u{eae8}", .color = colors.rgb(0xC2, 0xCA, 0xD3) };
const lock_file = FileIcon{ .glyph = "\u{ea75}", .color = colors.rgb(0xF2, 0xCC, 0x60) };
const gear_file = FileIcon{ .glyph = "\u{eaf8}", .color = colors.rgb(0xC8, 0xD0, 0xD9) };
const archive_file = FileIcon{ .glyph = "\u{ea98}", .color = colors.rgb(0xF0, 0xB0, 0x5C) };
const text_file = FileIcon{ .glyph = "\u{ec5e}", .color = colors.rgb(0xC5, 0xCF, 0xDA) };
const toml_file = FileIcon{ .glyph = "", .color = colors.rgb(0x9C, 0x42, 0x21) };
const typescript_file = FileIcon{ .glyph = "", .color = colors.rgb(0x51, 0x9A, 0xBA) };
const tsx_file = FileIcon{ .glyph = "", .color = colors.rgb(0x13, 0x54, 0xBF) };
const vue_file = FileIcon{ .glyph = "", .color = colors.rgb(0x8D, 0xC1, 0x49) };
const zig_file = FileIcon{ .glyph = "", .color = colors.rgb(0xF6, 0x9A, 0x1B) };
const env_file = FileIcon{ .glyph = "", .color = colors.rgb(0xFA, 0xF7, 0x43) };
const eslint_file = FileIcon{ .glyph = "", .color = colors.rgb(0x4B, 0x32, 0xC3) };
const git_file = FileIcon{ .glyph = "", .color = colors.rgb(0xF5, 0x4D, 0x27) };
const prettier_file = FileIcon{ .glyph = "", .color = colors.rgb(0x42, 0x85, 0xF4) };
const npm_file = FileIcon{ .glyph = "", .color = colors.rgb(0xE8, 0x27, 0x4B) };
const editorconfig_file = FileIcon{ .glyph = "", .color = colors.rgb(0xFF, 0xF2, 0xF2) };

pub fn forFile(file_name: []const u8) FileIcon {
    if (matchesSpecialName(file_name, &.{ ".gitignore", ".gitattributes" })) return git_file;
    if (matchesSpecialName(file_name, &.{".editorconfig"})) return editorconfig_file;
    if (matchesSpecialName(file_name, &.{ ".eslintrc", ".eslintignore" })) return eslint_file;
    if (matchesSpecialName(file_name, &.{ ".prettierrc", ".prettierignore" })) return prettier_file;
    if (matchesSpecialName(file_name, &.{ ".env", ".env.example" })) return env_file;
    if (matchesSpecialName(file_name, &.{ "package.json", "package-lock.json" })) return npm_file;
    if (matchesSpecialName(file_name, &.{ "tsconfig.json", "jsconfig.json" })) return typescript_file;
    if (matchesSpecialName(file_name, &.{ "build.zig", "build.zig.zon" })) return zig_file;
    if (matchesSpecialName(file_name, &.{"cargo.toml"})) return rust_file;
    if (matchesSpecialName(file_name, &.{ "dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", "containerfile", ".dockerignore" })) return gear_file;
    if (matchesSpecialName(file_name, &.{ "readme", "changelog", "contributing", "license" })) return markdown_file;
    if (matchesSpecialName(file_name, &.{ "makefile", "justfile", "procfile" })) return gear_file;
    if (isLockedFile(file_name)) return lock_file;

    const ext = extensionWithoutDot(file_name);
    if (ext.len == 0) return generic_file;

    if (matchesAnyIgnoreCase(ext, &.{ "zig", "zon" })) return zig_file;
    if (matchesAnyIgnoreCase(ext, &.{"rs"})) return rust_file;
    if (matchesAnyIgnoreCase(ext, &.{ "c", "m" })) return c_file;
    if (matchesAnyIgnoreCase(ext, &.{ "h", "hh", "hpp", "hxx" })) return c_header_file;
    if (matchesAnyIgnoreCase(ext, &.{ "cc", "cpp", "cxx", "c++", "cp", "cppm", "ixx" })) return cpp_file;
    if (matchesAnyIgnoreCase(ext, &.{"go"})) return go_file;
    if (matchesAnyIgnoreCase(ext, &.{"py"})) return python_file;
    if (matchesAnyIgnoreCase(ext, &.{"rb"})) return ruby_file;
    if (matchesAnyIgnoreCase(ext, &.{"php"})) return php_file;
    if (matchesAnyIgnoreCase(ext, &.{"java"})) return java_file;
    if (matchesAnyIgnoreCase(ext, &.{ "kt", "kts" })) return kotlin_file;
    if (matchesAnyIgnoreCase(ext, &.{ "lua", "luau", "luac" })) return lua_file;
    if (matchesAnyIgnoreCase(ext, &.{ "js", "mjs", "cjs" })) return javascript_file;
    if (matchesAnyIgnoreCase(ext, &.{"jsx"})) return jsx_file;
    if (matchesAnyIgnoreCase(ext, &.{ "ts", "cts", "mts" })) return typescript_file;
    if (matchesAnyIgnoreCase(ext, &.{"tsx"})) return tsx_file;
    if (matchesAnyIgnoreCase(ext, &.{ "json", "jsonc", "json5" })) return json_file;
    if (matchesAnyIgnoreCase(ext, &.{ "html", "htm" })) return html_file;
    if (matchesAnyIgnoreCase(ext, &.{"css"})) return css_file;
    if (matchesAnyIgnoreCase(ext, &.{ "scss", "sass" })) return sass_file;
    if (matchesAnyIgnoreCase(ext, &.{"less"})) return less_file;
    if (matchesAnyIgnoreCase(ext, &.{"vue"})) return vue_file;
    if (matchesAnyIgnoreCase(ext, &.{"svelte"})) return svelte_file;
    if (matchesAnyIgnoreCase(ext, &.{"astro"})) return astro_file;
    if (matchesAnyIgnoreCase(ext, &.{ "graphql", "gql" })) return graphql_file;
    if (matchesAnyIgnoreCase(ext, &.{ "md", "mdx", "markdown", "rst" })) return markdown_file;
    if (matchesAnyIgnoreCase(ext, &.{ "txt", "log", "csv", "tsv" })) return text_file;
    if (matchesAnyIgnoreCase(ext, &.{ "png", "jpg", "jpeg", "gif", "bmp", "webp", "avif", "ico", "svg", "mp4", "mov", "webm", "mp3", "wav", "ogg", "flac" })) return media_file;
    if (matchesAnyIgnoreCase(ext, &.{"pdf"})) return pdf_file;
    if (matchesAnyIgnoreCase(ext, &.{ "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar" })) return archive_file;
    if (matchesAnyIgnoreCase(ext, &.{ "db", "sqlite", "sqlite3" })) return sql_file;
    if (matchesAnyIgnoreCase(ext, &.{"sql"})) return sql_file;
    if (matchesAnyIgnoreCase(ext, &.{ "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd" })) return shell_file;
    if (matchesAnyIgnoreCase(ext, &.{"toml"})) return toml_file;
    if (matchesAnyIgnoreCase(ext, &.{ "yaml", "yml", "ini", "conf", "cfg" })) return gear_file;
    if (matchesAnyIgnoreCase(ext, &.{ "exe", "dll", "so", "dylib", "a", "o", "bin" })) return binary_file;
    if (matchesAnyIgnoreCase(ext, &.{"lock"})) return archive_file;
    if (isCodeLikeExtension(ext)) return generic_code_file;

    return generic_file;
}

fn extensionWithoutDot(file_name: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_name);
    return if (ext.len > 0) ext[1..] else "";
}

fn isLockedFile(file_name: []const u8) bool {
    if (std.mem.startsWith(u8, file_name, ".env")) return true;
    return matchesSpecialName(file_name, &.{ "id_rsa", "id_ed25519", "known_hosts" }) or matchesAnyIgnoreCase(extensionWithoutDot(file_name), &.{ "pem", "key", "crt", "cer", "p12", "pfx" });
}

fn isCodeLikeExtension(ext: []const u8) bool {
    return matchesAnyIgnoreCase(ext, &.{
        "swift", "dart", "scala", "clj", "cljs", "cljc", "ex", "exs", "elm", "erl", "hrl", "hs", "lhs", "ml", "mli", "fs", "fsi", "fsx", "r", "jl", "tex", "xml", "nix", "vim", "zig.zon",
    });
}

fn matchesSpecialName(file_name: []const u8, comptime names: []const []const u8) bool {
    const stem = stemWithoutExtension(file_name);
    inline for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(file_name, candidate)) return true;
        if (std.ascii.eqlIgnoreCase(stem, candidate)) return true;
    }
    return false;
}

fn stemWithoutExtension(file_name: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_name);
    if (ext.len == 0) return file_name;
    return file_name[0 .. file_name.len - ext.len];
}

fn matchesAnyIgnoreCase(value: []const u8, comptime candidates: []const []const u8) bool {
    inline for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}
