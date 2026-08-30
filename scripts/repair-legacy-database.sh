#!/bin/sh
set -eu

fail() {
  printf 'verde database repair: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this repair is only for macOS"
command -v sqlite3 >/dev/null 2>&1 || fail "missing required command: sqlite3"

if command -v verde >/dev/null 2>&1; then
  verde_bin="$(command -v verde)"
elif [ -x /Applications/Verde.app/Contents/MacOS/verde ]; then
  verde_bin="/Applications/Verde.app/Contents/MacOS/verde"
elif [ -x "$HOME/Applications/Verde.app/Contents/MacOS/verde" ]; then
  verde_bin="$HOME/Applications/Verde.app/Contents/MacOS/verde"
else
  fail "Verde is not installed"
fi

db_path="$("$verde_bin" state path)"
[ -f "$db_path" ] || fail "database not found at $db_path"

schema_version="$(sqlite3 "$db_path" 'pragma user_version;')"
case "$schema_version" in
  ''|*[!0-9]*) fail "database returned an invalid schema version" ;;
esac

if [ "$schema_version" -gt 0 ]; then
  printf 'Verde database schema is already version %s. No repair is needed.\n' "$schema_version"
  exit 0
fi

backup_path="$db_path.pre-legacy-repair.$(date +%Y%m%d%H%M%S).bak"
sqlite3 "$db_path" ".backup '$backup_path'"
printf 'Backed up the Verde database to %s\n' "$backup_path"

if ! "$verde_bin" core status --json >/dev/null; then
  fail "migration failed; the original database is unchanged and the backup is at $backup_path"
fi

migrated_version="$(sqlite3 "$db_path" 'pragma user_version;')"
case "$migrated_version" in
  ''|*[!0-9]*|0) fail "migration did not advance the schema; backup: $backup_path" ;;
esac

printf 'Verde database repaired successfully (schema version %s). Open Verde again.\n' "$migrated_version"
