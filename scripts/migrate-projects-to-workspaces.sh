#!/usr/bin/env bash
set -euo pipefail

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required" >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [path/to/state.sqlite]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  db_path="$1"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  db_path="${HOME}/Library/Application Support/verde/Native/state.sqlite"
else
  db_path="${XDG_DATA_HOME:-${HOME}/.local/share}/verde/Native/state.sqlite"
fi

if [[ ! -f "$db_path" ]]; then
  echo "state database not found: $db_path" >&2
  exit 3
fi

backup_path="${db_path}.project-to-workspace.$(date +%Y%m%d%H%M%S).bak"
cp "$db_path" "$backup_path"
echo "backup: $backup_path"

table_exists() {
  sqlite3 "$db_path" "select count(*) from sqlite_master where type = 'table' and name = '$1';"
}

column_exists() {
  sqlite3 "$db_path" "select count(*) from pragma_table_info('$1') where name = '$2';"
}

row_count() {
  sqlite3 "$db_path" "select count(*) from $1;"
}

sqlite3 "$db_path" "pragma foreign_keys = off;"

if [[ "$(table_exists projects)" == "1" && "$(table_exists workspaces)" == "1" && "$(row_count workspaces)" == "0" ]]; then
  sqlite3 "$db_path" "drop index if exists workspaces_sort_index_idx; drop table workspaces;"
fi

if [[ "$(table_exists projects)" == "1" && "$(table_exists workspaces)" == "0" ]]; then
  sqlite3 "$db_path" "drop index if exists projects_sort_index_idx; alter table projects rename to workspaces;"
fi

if [[ "$(column_exists workspaces project_id)" == "1" ]]; then
  sqlite3 "$db_path" "alter table workspaces rename column project_id to workspace_id;"
fi

if [[ "$(column_exists threads project_id)" == "1" ]]; then
  sqlite3 "$db_path" "alter table threads rename column project_id to workspace_id;"
fi

if [[ "$(column_exists app_state selected_project_index)" == "1" ]]; then
  sqlite3 "$db_path" "alter table app_state rename column selected_project_index to selected_workspace_index;"
fi

sqlite3 "$db_path" "create unique index if not exists workspaces_sort_index_idx on workspaces(sort_index); pragma foreign_keys = on;"

echo "migrated: $db_path"
