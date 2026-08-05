//! Native state database ownership and legacy JSON loading.

const std = @import("std");
const sdl = @import("zsdl3");
const db_client = @import("../db/client.zig");
const db_types = @import("../db/types.zig");

const ORG_NAME: [:0]const u8 = "verde";
const APP_NAME: [:0]const u8 = "Native";
pub const LEGACY_STATE_FILE_NAME = "state.json";
const LoadedPersistedState = db_types.LoadedState;
const PersistedState = db_types.PersistedState;
const PersistedThread = db_types.PersistedThread;

pub const Storage = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    client: db_client.Client,

    pub fn init(allocator: std.mem.Allocator) !Storage {
        const pref_path = sdl.getPrefPath(ORG_NAME, APP_NAME) orelse return error.SdlError;
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);
        const client = try db_client.Client.init(allocator, owned_pref_path);
        errdefer {
            var owned_client = client;
            owned_client.deinit();
        }
        return .{
            .allocator = allocator,
            .pref_path = owned_pref_path,
            .client = client,
        };
    }

    pub fn deinit(self: *Storage) void {
        self.client.deinit();
        self.allocator.free(self.pref_path);
    }

    pub fn load(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        if (try self.client.load(allocator)) |loaded| {
            return loaded;
        }
        if (try self.loadLegacyJson(allocator)) |loaded| {
            errdefer {
                var owned_loaded = loaded;
                owned_loaded.deinit();
            }
            try self.client.save(loaded.value);
            return loaded;
        }
        return null;
    }

    pub fn loadLegacyJson(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.pref_path, .{});
        defer dir.close(threaded.io());

        const bytes = dir.readFileAlloc(threaded.io(), LEGACY_STATE_FILE_NAME, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);

        var loaded = LoadedPersistedState.init(allocator);
        errdefer loaded.deinit();
        loaded.value = try std.json.parseFromSliceLeaky(PersistedState, loaded.allocator(), bytes, .{
            .allocate = .alloc_always,
        });
        return loaded;
    }

    pub fn save(self: *const Storage, state: PersistedState) !void {
        try self.client.save(state);
    }

    pub fn saveThread(self: *const Storage, workspace_id: []const u8, thread_index: usize, thread: PersistedThread) !void {
        try self.client.saveThread(workspace_id, thread_index, thread);
    }
};
