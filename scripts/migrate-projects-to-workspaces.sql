pragma foreign_keys = off;

drop index if exists projects_sort_index_idx;

alter table projects rename to workspaces;
alter table workspaces rename column project_id to workspace_id;
alter table threads rename column project_id to workspace_id;
alter table app_state rename column selected_project_index to selected_workspace_index;

create unique index if not exists workspaces_sort_index_idx on workspaces(sort_index);

pragma foreign_keys = on;
