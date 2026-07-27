//! Active and archived project collection ownership.

const std = @import("std");
const project = @import("project.zig");

pub const State = struct {
    projects: std.ArrayList(project.Project) = .empty,
    archived_projects: std.ArrayList(project.Project) = .empty,
    selected_index: usize = 0,
    next_project_number: usize = 4,
    show_creator: bool = false,
};

pub fn currentProject(self: anytype) *const project.Project {
    return &self.project_controller.projects.items[self.project_controller.selected_index];
}

pub fn currentProjectMutable(self: anytype) *project.Project {
    return &self.project_controller.projects.items[self.project_controller.selected_index];
}
