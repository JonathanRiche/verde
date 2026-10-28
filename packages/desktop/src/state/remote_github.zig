//! GitHub CLI (`gh`) on a remote runtime: the status probe, the user-space
//! installer, and the sign-in command Settings > Connections offers under a
//! runtime's providers.
//!
//! Everything runs on the runtime over the terminal RPC lane, so it works
//! with runtime daemons that know nothing about GitHub. The runtime user has
//! no root: gh goes under ~/.local, and every command puts ~/.local/bin on
//! PATH itself rather than trusting the login profile to. Probe output names
//! the GitHub account; it is parsed in memory, wiped, never logged or shown.

const std = @import("std");
const auth_probe = @import("remote_auth_probe.zig");

/// Printed by the probe when `gh` is not on PATH (exit 127).
pub const MISSING_MARKER = "verde-gh-missing";

/// Puts the installer's ~/.local/bin first so a user-space gh is found (and
/// `gh auth setup-git` records that path for git's credential helper).
const PATH_PREFIX = "export PATH=\"$HOME/.local/bin:$PATH\"; ";

/// Non-interactive status probe for `bash -lc`: from the runtime user's
/// home, no terminal input, no update check.
pub const PROBE_SHELL = "cd \"$HOME\" 2>/dev/null; " ++ PATH_PREFIX ++
    "command -v gh >/dev/null 2>&1 || { echo " ++ MISSING_MARKER ++ "; exit 127; }; " ++
    "GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 gh auth status --hostname github.com </dev/null";

/// Device-code sign-in. gh treats a terminal stdin as interactive: it then
/// asks "Authenticate Git with your GitHub credentials?" and blocks on
/// "Press Enter to open <url> in your browser..." before it polls GitHub.
/// Reading stdin from /dev/null makes it non-interactive (gh 2.x checks
/// stdin and stdout are TTYs), so it prints the one-time code and the
/// github.com/login/device URL and polls right away. The dialog still sends
/// one Enter once the code shows (`shouldAutoEnter`) for any gh that waits
/// anyway. Non-interactive login skips gh's own Git setup, so `--scopes
/// workflow` (which that setup adds, for pushes touching workflows) is asked
/// for here and `gh auth setup-git` runs after. `--clipboard=false`, where
/// gh has it, avoids its "Failed to copy one-time code" noise on a headless
/// VM. The browser variables print a URL instead of launching anything.
pub const SIGN_IN_SHELL = PATH_PREFIX ++
    "command -v gh >/dev/null 2>&1 || { echo 'The GitHub CLI (gh) is not installed on this runtime. Go back and choose Install.'; exit 127; }; " ++
    "export GH_BROWSER=echo BROWSER=echo GH_NO_UPDATE_NOTIFIER=1; " ++
    "clip=; gh auth login --help 2>&1 | grep -q -- --clipboard && clip=--clipboard=false; " ++
    "gh auth login --hostname github.com --git-protocol https --web --scopes workflow $clip </dev/null && gh auth setup-git && " ++
    "echo 'Signed in. Git on this runtime now uses this GitHub account for github.com.'";

/// User-space install of the latest official gh release for Linux
/// amd64/arm64: resolves the release from github.com's redirect (no API rate
/// limit), verifies the tarball against the release's checksums file,
/// unpacks it to ~/.local/share/gh/<version>, and links ~/.local/bin/gh. No
/// root needed. curl honors the runtime's HTTPS_PROXY. Runs in a subshell so
/// `set -eu` and the cleanup trap end with it.
pub const INSTALL_SHELL =
    \\(
    \\set -eu
    \\case "$(uname -s)" in Linux) ;; *) echo "Verde installs the GitHub CLI on Linux runtimes only." >&2; exit 1 ;; esac
    \\case "$(uname -m)" in
    \\  x86_64|amd64) arch=amd64 ;;
    \\  aarch64|arm64) arch=arm64 ;;
    \\  *) echo "No GitHub CLI build for this CPU ($(uname -m))." >&2; exit 1 ;;
    \\esac
    \\echo "Finding the latest GitHub CLI release..."
    \\latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest)
    \\tag=${latest##*/}
    \\version=${tag#v}
    \\case "$version" in ''|*[!0-9.]*) echo "Could not read the latest release from $latest" >&2; exit 1 ;; esac
    \\name="gh_${version}_linux_${arch}"
    \\base="https://github.com/cli/cli/releases/download/$tag"
    \\tmp=$(mktemp -d)
    \\trap 'rm -rf "$tmp"' EXIT
    \\echo "Downloading GitHub CLI $version ($arch)..."
    \\curl -fsSL --retry 3 -o "$tmp/$name.tar.gz" "$base/$name.tar.gz"
    \\curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/gh_${version}_checksums.txt"
    \\expected=$(awk -v file="$name.tar.gz" '$2 == file { print $1 }' "$tmp/checksums.txt")
    \\actual=$(sha256sum "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
    \\if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then echo "Checksum mismatch for $name.tar.gz; nothing was installed." >&2; exit 1; fi
    \\echo "Checksum verified."
    \\tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    \\dest="$HOME/.local/share/gh/$version"
    \\mkdir -p "$HOME/.local/share/gh" "$HOME/.local/bin"
    \\rm -rf "$dest"
    \\mv "$tmp/$name" "$dest"
    \\ln -sfn "$dest/bin/gh" "$HOME/.local/bin/gh"
    \\"$HOME/.local/bin/gh" --version
    \\echo "Installed to $dest and linked $HOME/.local/bin/gh."
    \\)
;

/// Where a device-code sign-in is approved.
pub const DEVICE_URL = "https://github.com/login/device";

/// Short descriptions shown beside the Settings buttons (the commands
/// themselves are long; the setup terminal shows what they do).
pub const INSTALL_AND_SIGN_IN_SUMMARY = "Installs the official GitHub CLI into ~/.local (checksum verified, no sudo), then signs in";
pub const SIGN_IN_SUMMARY = "gh auth login with a one-time code, then git uses it for github.com";

/// Longest device code kept; GitHub's are `XXXX-XXXX`.
pub const MAX_DEVICE_CODE_LEN: usize = 16;

pub const Status = enum { unknown, missing, signed_out, signed_in };

/// Latest probe outcome for one runtime profile.
pub const Entry = struct {
    profile_id: []u8,
    /// When the last probe finished; 0 means due now.
    probed_at_ms: i64 = 0,
    /// Null until a probe has finished since the entry was (re)armed.
    status: ?Status = null,
};

/// Maps a finished probe. `exit_code` is null for a signal or unknown exit.
/// gh prints "Logged in to github.com account X" (older: "as X") and exits 0
/// when signed in; "You are not logged into any GitHub hosts" or "Failed to
/// log in" with exit 1 when not.
pub fn parseProbe(output: []const u8, exit_code: ?u32) Status {
    if (std.mem.indexOf(u8, output, MISSING_MARKER) != null) return .missing;
    if (exit_code) |code| switch (code) {
        0 => return .signed_in,
        // `command not found` from a shell that never reached the marker.
        127 => return .missing,
        else => {},
    };
    if (containsIgnoreCase(output, "not logged in") or containsIgnoreCase(output, "failed to log in")) return .signed_out;
    if (std.mem.indexOf(u8, output, "Logged in to github.com") != null) return .signed_in;
    if (exit_code == @as(?u32, 1)) return .signed_out;
    return .unknown;
}

/// The one-time code from `gh auth login --web` output ("! First copy your
/// one-time code: 1A2B-3C4D", or "! One-time code (1A2B-3C4D) copied to
/// clipboard", possibly bold), copied into `out`; null until it has been
/// printed. The code is shown to the user, never logged.
pub fn parseDeviceCode(output: []const u8, out: *[MAX_DEVICE_CODE_LEN]u8) ?[]const u8 {
    var buffer: [4096]u8 = undefined;
    // The code comes within the first lines; later output is irrelevant.
    const clean = auth_probe.stripEscapes(output[0..@min(output.len, buffer.len)], &buffer);
    const rest = if (std.mem.indexOf(u8, clean, "one-time code:")) |at|
        std.mem.trimStart(u8, clean[at + "one-time code:".len ..], " \t")
    else if (std.mem.indexOf(u8, clean, "One-time code (")) |at|
        clean[at + "One-time code (".len ..]
    else
        return null;
    var len: usize = 0;
    while (len < rest.len and len < out.len and (std.ascii.isAlphanumeric(rest[len]) or rest[len] == '-')) : (len += 1) {}
    // Still arriving (no terminator yet), or not a code.
    if (len == rest.len or len < 6 or std.mem.indexOfScalar(u8, rest[0..len], '-') == null) return null;
    @memcpy(out[0..len], rest[0..len]);
    return out[0..len];
}

/// gh is waiting for Enter before it opens the browser and polls.
pub fn promptsForEnter(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "Press Enter") != null;
}

/// Whether a running sign-in should get its one Enter now: once the code
/// or gh's "Press Enter" prompt is out, never twice, never before.
pub fn shouldAutoEnter(already_sent: bool, has_code: bool, output: []const u8) bool {
    if (already_sent) return false;
    return has_code or promptsForEnter(output);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return needle.len == 0;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "gh status probe output maps to account state" {
    try std.testing.expectEqual(Status.signed_in, parseProbe("github.com\r\n  \xe2\x9c\x93 Logged in to github.com account someone (keyring)\r\n", 0));
    try std.testing.expectEqual(Status.signed_in, parseProbe("", 0));
    // Older gh wording, exit status unknown.
    try std.testing.expectEqual(Status.signed_in, parseProbe("\xe2\x9c\x93 Logged in to github.com as someone (~/.config/gh/hosts.yml)\r\n", null));
    try std.testing.expectEqual(Status.signed_out, parseProbe("You are not logged into any GitHub hosts. To log in, run: gh auth login\r\n", 1));
    try std.testing.expectEqual(Status.signed_out, parseProbe("github.com\r\n  X Failed to log in to github.com account someone (default)\r\n  - The token in GH_TOKEN is invalid.\r\n", 1));
    try std.testing.expectEqual(Status.signed_out, parseProbe("unexpected\r\n", 1));
    try std.testing.expectEqual(Status.missing, parseProbe(MISSING_MARKER ++ "\r\n", 127));
    try std.testing.expectEqual(Status.missing, parseProbe(MISSING_MARKER ++ "\r\n", null));
    try std.testing.expectEqual(Status.missing, parseProbe("bash: gh: command not found\r\n", 127));
    try std.testing.expectEqual(Status.unknown, parseProbe("", null));
    try std.testing.expectEqual(Status.unknown, parseProbe("keyring timeout", 4));
}

test "gh device code is read from sign-in output" {
    var out: [MAX_DEVICE_CODE_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("1A2B-3C4D", parseDeviceCode("\x1b[0;33m!\x1b[0m First copy your one-time code: \x1b[1m1A2B-3C4D\x1b[0m\r\nOpen this URL to continue in your web browser: https://github.com/login/device\r\n", &out).?);
    try std.testing.expectEqualStrings("ABCD-EF12", parseDeviceCode("! First copy your one-time code: ABCD-EF12\n", &out).?);
    // Not printed yet, or cut mid-code by a tail boundary.
    try std.testing.expect(parseDeviceCode("Starting...\r\n", &out) == null);
    try std.testing.expect(parseDeviceCode("! First copy your one-time code: 1A2B-3", &out) == null);
    try std.testing.expect(parseDeviceCode("one-time code: none\n", &out) == null);
    // gh with a working clipboard prints the code in parentheses instead.
    try std.testing.expectEqualStrings("9Z8Y-7X6W", parseDeviceCode("! One-time code (\x1b[1m9Z8Y-7X6W\x1b[0m) copied to clipboard\r\n", &out).?);
}

test "sign-in gets one Enter after the code or prompt, never before or twice" {
    try std.testing.expect(!shouldAutoEnter(false, false, ""));
    try std.testing.expect(!shouldAutoEnter(false, false, "! Failed to copy one-time code to clipboard\r\n"));
    try std.testing.expect(shouldAutoEnter(false, true, "! First copy your one-time code: 1A2B-3C4D\r\n"));
    try std.testing.expect(shouldAutoEnter(false, false, "\x1b[1mPress Enter\x1b[0m to open https://github.com/login/device in your browser... "));
    try std.testing.expect(!shouldAutoEnter(true, true, "Press Enter to open"));
}

test "gh commands put the user-space bin on PATH and never prompt or open a browser" {
    try std.testing.expect(std.mem.indexOf(u8, PROBE_SHELL, "gh auth status --hostname github.com </dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, PROBE_SHELL, PATH_PREFIX) != null);
    try std.testing.expect(std.mem.indexOf(u8, PROBE_SHELL, "echo " ++ MISSING_MARKER) != null);
    try std.testing.expect(std.mem.startsWith(u8, SIGN_IN_SHELL, PATH_PREFIX));
    // stdin from /dev/null: gh never blocks on "Press Enter" or a Git prompt.
    try std.testing.expect(std.mem.indexOf(u8, SIGN_IN_SHELL, "gh auth login --hostname github.com --git-protocol https --web --scopes workflow $clip </dev/null && gh auth setup-git") != null);
    try std.testing.expect(std.mem.indexOf(u8, SIGN_IN_SHELL, "grep -q -- --clipboard && clip=--clipboard=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, SIGN_IN_SHELL, "GH_BROWSER=echo BROWSER=echo") != null);
}

test "gh installer is a rootless, checksum-verified user-space install" {
    const shell = INSTALL_SHELL;
    // One subshell, so `set -eu` and the trap end with the install.
    try std.testing.expect(std.mem.startsWith(u8, shell, "(\nset -eu\n"));
    try std.testing.expect(std.mem.endsWith(u8, shell, "\n)"));
    try std.testing.expect(std.mem.indexOf(u8, shell, "sudo") == null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "x86_64|amd64) arch=amd64") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "aarch64|arm64) arch=arm64") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "https://github.com/cli/cli/releases/latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "https://github.com/cli/cli/releases/download/$tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "name=\"gh_${version}_linux_${arch}\"") != null);
    // The tarball is checked against the release's own checksums file, and
    // a mismatch exits before anything is unpacked into $HOME.
    const checksums = std.mem.indexOf(u8, shell, "gh_${version}_checksums.txt").?;
    const compare = std.mem.indexOf(u8, shell, "[ \"$expected\" != \"$actual\" ]").?;
    const unpack = std.mem.indexOf(u8, shell, "tar -xzf").?;
    try std.testing.expect(checksums < compare and compare < unpack);
    try std.testing.expect(std.mem.indexOf(u8, shell, "dest=\"$HOME/.local/share/gh/$version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "ln -sfn \"$dest/bin/gh\" \"$HOME/.local/bin/gh\"") != null);
    // Every line is plain POSIX sh: no bash-only constructs.
    try std.testing.expect(std.mem.indexOf(u8, shell, "[[") == null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "$'") == null);
}
