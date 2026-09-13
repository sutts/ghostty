//! Persists and restores the window/tab/split layout and per-split working
//! directories across restarts, gated by the `window-save-state` config
//! option. This is the GTK apprt's equivalent of macOS's native window
//! restoration; there is no OS-level session restoration on Linux, so this
//! implements it directly with a small JSON state file.
const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const configpkg = @import("../../config.zig");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_session_state);

/// Maximum size of the state file we'll read. This is arbitrary but
/// generous; a real session file is a few KB even with many splits.
const max_state_file_size = 8 * 1024 * 1024;

/// The on-disk shape of the session state file.
pub const State = struct {
    version: u32 = 1,
    windows: []const WindowState = &.{},
};

pub const WindowState = struct {
    width: i32,
    height: i32,
    maximized: bool,
    active_tab: usize,
    tabs: []const TabState,
};

pub const TabState = struct {
    title: ?[]const u8 = null,
    tree: TreeNode,
};

/// A node in a persisted split tree. Deliberately a plain recursive value
/// (not the flat handle-indexed array the live `SplitTree` uses), since
/// this needs to remain stable on disk independent of that internal
/// representation.
pub const TreeNode = union(enum) {
    leaf: Leaf,
    split: Split,
};

pub const Leaf = struct {
    /// The split's working directory, if known. This is only ever known
    /// when shell integration reported it (via OSC 7) before exit; a split
    /// with no shell integration, or one that never reported a pwd, has
    /// this set to null and restores using ordinary default-cwd resolution.
    pwd: ?[]const u8 = null,
};

pub const Split = struct {
    layout: enum { horizontal, vertical },
    ratio: f32,
    left: *const TreeNode,
    right: *const TreeNode,
};

/// A loaded state file, along with the arena backing all of its slices
/// and pointers. Call `deinit` when done with `state`.
pub const LoadedState = struct {
    arena: std.heap.ArenaAllocator,
    state: State,

    pub fn deinit(self: *LoadedState) void {
        self.arena.deinit();
    }
};

/// Save the current window/tab/split layout and working directories to
/// disk, if `window-save-state` is set to `always`. Intended to be called
/// once, on a clean exit, before any windows are destroyed. Never fails
/// the caller; errors are logged and swallowed.
pub fn save(app: *Application) void {
    const config = app.getConfig().get();
    if (config.@"window-save-state" != .always) {
        log.debug("session state save skipped: window-save-state is not 'always'", .{});
        return;
    }

    log.info("saving window session state", .{});
    saveInner(app) catch |err| {
        log.warn("failed to save window session state: {}", .{err});
    };
}

/// Walk all open toplevel windows and collect their layout into
/// `WindowState`s, skipping any window with no surfaces.
fn collectWindowStates(arena: Allocator) ![]WindowState {
    var windows: std.ArrayList(WindowState) = .empty;

    const list = gtk.Window.listToplevels();
    defer list.free();

    var node_: ?*glib.List = list;
    while (node_) |node| : (node_ = node.f_next) {
        const data = node.f_data orelse continue;
        const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
        const window = gobject.ext.cast(Window, gtk_window) orelse continue;

        const ws = saveWindow(arena, window) catch |err| {
            log.warn("failed to save a window's layout: {}", .{err});
            continue;
        };
        if (ws.tabs.len > 0) try windows.append(arena, ws);
    }

    return windows.items;
}

fn saveInner(app: *Application) !void {
    const gpa = app.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const windows = try collectWindowStates(arena);

    // If we found nothing to save, leave whatever's already on disk alone
    // rather than overwriting it with an empty session. This matters
    // because closing an app's last window saves state right before that
    // window is destroyed (see `Window.saveSessionIfLastWindow`); the main
    // loop then notices zero windows remain and calls `quitNow` again as
    // its own force-quit cleanup, which must not clobber that save with
    // an empty one just because, by then, there's genuinely nothing left
    // to walk.
    if (windows.len == 0) {
        log.debug("session state save skipped: no windows with surfaces to save", .{});
        return;
    }

    var total_tabs: usize = 0;
    for (windows) |w| total_tabs += w.tabs.len;

    const state: State = .{ .windows = windows };
    const path = try statePath(gpa);
    defer gpa.free(path);
    try writeJsonFile(path, state);
    log.info(
        "session state saved: {d} window(s), {d} tab(s)",
        .{ windows.len, total_tabs },
    );
}

fn saveWindow(arena: Allocator, window: *Window) !WindowState {
    const tab_view = window.getTabView();
    const n: usize = @intCast(tab_view.getNPages());
    const selected = tab_view.getSelectedPage();

    var tabs: std.ArrayList(TabState) = .empty;
    var active_tab: usize = 0;

    for (0..n) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;

        try tabs.append(arena, .{
            .title = null,
            .tree = try saveNode(arena, tree, .root),
        });
        if (selected) |sel| if (page == sel) {
            active_tab = tabs.items.len - 1;
        };
    }

    return .{
        .width = window.as(gtk.Widget).getWidth(),
        .height = window.as(gtk.Widget).getHeight(),
        .maximized = window.isMaximized(),
        .active_tab = active_tab,
        .tabs = tabs.items,
    };
}

fn saveNode(
    arena: Allocator,
    tree: *const Surface.Tree,
    handle: Surface.Tree.Node.Handle,
) !TreeNode {
    return switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| .{ .leaf = .{
            .pwd = if (surface.getPwd()) |pwd| try arena.dupe(u8, pwd) else null,
        } },
        .split => |s| blk: {
            const left = try arena.create(TreeNode);
            left.* = try saveNode(arena, tree, s.left);
            const right = try arena.create(TreeNode);
            right.* = try saveNode(arena, tree, s.right);
            break :blk .{ .split = .{
                .layout = switch (s.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = s.ratio,
                .left = left,
                .right = right,
            } };
        },
    };
}

/// Load the session state file, if `window-save-state` is `always` and a
/// valid state file exists. Returns null if the feature is disabled, the
/// file doesn't exist, or it fails to parse -- restoring session state
/// must never block normal startup.
pub fn tryLoad(gpa: Allocator, config: *const configpkg.Config) ?LoadedState {
    if (config.@"window-save-state" != .always) {
        log.debug("session state restore skipped: window-save-state is not 'always'", .{});
        return null;
    }

    return tryLoadInner(gpa) catch |err| {
        switch (err) {
            error.FileNotFound => log.debug(
                "session state restore skipped: no saved session file found",
                .{},
            ),
            else => log.warn("failed to load window session state: {}", .{err}),
        }
        return null;
    };
}

fn tryLoadInner(gpa: Allocator) !LoadedState {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try statePath(arena);
    log.info("loading window session state from {s}", .{path});
    const content = try readFile(arena, path);
    const state = try std.json.parseFromSliceLeaky(State, arena, content, .{});
    log.info("session state loaded: {d} window(s)", .{state.windows.len});

    return .{ .arena = arena_state, .state = state };
}

/// Recursively build a live `Surface.Tree` (creating real `Surface`
/// objects for each leaf) from a persisted `TreeNode`. The caller owns the
/// returned tree and must `deinit` it once it's been installed with
/// `SplitTree.setTree`.
pub fn buildTree(gpa: Allocator, node: TreeNode) !Surface.Tree {
    return switch (node) {
        .leaf => |leaf| blk: {
            const wd: ?[:0]const u8 = if (leaf.pwd) |p| try gpa.dupeZ(u8, p) else null;
            defer if (wd) |w| gpa.free(w);

            const surface: *Surface = .new(.{ .working_directory = wd });
            defer surface.unref();
            _ = surface.refSink();

            break :blk try Surface.Tree.init(gpa, surface);
        },
        .split => |s| blk: {
            var left_tree = try buildTree(gpa, s.left.*);
            defer left_tree.deinit();
            var right_tree = try buildTree(gpa, s.right.*);
            defer right_tree.deinit();

            const direction: Surface.Tree.Split.Direction = switch (s.layout) {
                .horizontal => .right,
                .vertical => .down,
            };

            break :blk try left_tree.split(
                gpa,
                .root,
                direction,
                @floatCast(s.ratio),
                &right_tree,
            );
        },
    };
}

fn statePath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const state_dir = try internal_os.xdg.state(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "ghostty" },
    );
    defer alloc.free(state_dir);
    return try std.fs.path.join(alloc, &.{ state_dir, "session.json" });
}

fn readFile(alloc: Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(global.io(), path, .{});
    defer file.close(global.io());
    var reader = file.reader(global.io(), &.{});
    return try reader.interface.allocRemaining(alloc, .limited(max_state_file_size));
}

fn writeJsonFile(path: []const u8, value: anytype) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidSessionPath;
    std.Io.Dir.cwd().createDirPath(global.io(), dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.Io.Dir.cwd().openDir(global.io(), dir_path, .{});
    defer dir.close(global.io());

    var atomic_file = try dir.createFileAtomic(global.io(), std.fs.path.basename(path), .{
        .replace = true,
    });
    defer atomic_file.deinit(global.io());

    var buf: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(global.io(), &buf);
    try file_writer.interface.print("{f}\n", .{std.json.fmt(value, .{
        .whitespace = .indent_2,
    })});
    try file_writer.flush();
    try atomic_file.replace(global.io());
}

/// A named, user-saved layout snapshot (see "Save Profile…"/"Restore
/// Profile" in the app menu). Unlike the automatic `State` session file,
/// profiles are explicit, multiple, and never overwritten except by
/// re-saving under the same name.
pub const ProfileFile = struct {
    /// Display name, as entered by the user. Kept separately from the
    /// on-disk filename (which is a sanitized version of this) so the
    /// original name -- including characters not safe in a filename --
    /// round-trips exactly for display.
    name: []const u8,
    state: State,
};

/// One entry in the saved-profiles list.
pub const ProfileEntry = struct {
    name: []const u8,
    /// Filename (including the .json extension) inside the profiles
    /// directory. Pass this to `loadProfile` to load this specific entry.
    filename: []const u8,
};

fn profilesDir(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const state_dir = try internal_os.xdg.state(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "ghostty" },
    );
    defer alloc.free(state_dir);
    return try std.fs.path.join(alloc, &.{ state_dir, "profiles" });
}

/// Turn a user-entered profile name into a filesystem-safe file stem.
/// Path separators and control characters become `_`; everything else
/// (including spaces and non-ASCII text) passes through unchanged. This
/// also neutralizes `.`/`..` as meaningful path segments, since the result
/// always has `.json` appended before being joined to the profiles
/// directory.
fn sanitizeFilename(alloc: Allocator, name: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, name);
    for (out) |*c| {
        if (c.* == '/' or c.* == '\\' or c.* < 0x20 or c.* == 0x7f) c.* = '_';
    }
    return out;
}

fn profilePathForName(alloc: Allocator, name: []const u8) ![]const u8 {
    const stem = try sanitizeFilename(alloc, name);
    defer alloc.free(stem);
    const filename = try std.fmt.allocPrint(alloc, "{s}.json", .{stem});
    defer alloc.free(filename);
    return try profilePathForFilename(alloc, filename);
}

fn profilePathForFilename(alloc: Allocator, filename: []const u8) ![]const u8 {
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, filename });
}

/// Save the current window/tab/split layout under the given name,
/// overwriting any existing profile with the same name. Unlike `save`,
/// this always runs regardless of `window-save-state` -- it's an explicit
/// user action, not the automatic quit-time save.
pub fn saveProfile(app: *Application, name: []const u8) !void {
    const gpa = app.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const windows = try collectWindowStates(arena);
    const profile: ProfileFile = .{ .name = name, .state = .{ .windows = windows } };

    const path = try profilePathForName(gpa, name);
    defer gpa.free(path);
    try writeJsonFile(path, profile);

    var total_tabs: usize = 0;
    for (windows) |w| total_tabs += w.tabs.len;
    log.info(
        "profile '{s}' saved: {d} window(s), {d} tab(s)",
        .{ name, windows.len, total_tabs },
    );
}

/// List saved profiles, sorted by display name. Never fails the caller;
/// errors (including the profiles directory not existing yet) are logged
/// and an empty list is returned. The caller must free the result with
/// `freeProfileEntries`.
pub fn listProfiles(gpa: Allocator) []ProfileEntry {
    return listProfilesInner(gpa) catch |err| {
        log.warn("failed to list saved profiles: {}", .{err});
        return &.{};
    };
}

fn listProfilesInner(gpa: Allocator) ![]ProfileEntry {
    const dir_path = try profilesDir(gpa);
    defer gpa.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(global.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(global.io());

    var entries: std.ArrayList(ProfileEntry) = .empty;

    var it = dir.iterate();
    while (try it.next(global.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(path);
        const content = readFile(gpa, path) catch |err| {
            log.warn("failed to read profile file {s}: {}", .{ entry.name, err });
            continue;
        };
        defer gpa.free(content);

        const parsed = std.json.parseFromSlice(
            ProfileFile,
            gpa,
            content,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.warn("failed to parse profile file {s}: {}", .{ entry.name, err });
            continue;
        };
        defer parsed.deinit();

        try entries.append(gpa, .{
            .name = try gpa.dupe(u8, parsed.value.name),
            .filename = try gpa.dupe(u8, entry.name),
        });
    }

    std.mem.sort(ProfileEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ProfileEntry, b: ProfileEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return try entries.toOwnedSlice(gpa);
}

pub fn freeProfileEntries(gpa: Allocator, entries: []ProfileEntry) void {
    for (entries) |e| {
        gpa.free(e.name);
        gpa.free(e.filename);
    }
    gpa.free(entries);
}

/// A loaded profile file, along with the arena backing it. Call `deinit`
/// when done with `profile`.
pub const LoadedProfile = struct {
    arena: std.heap.ArenaAllocator,
    profile: ProfileFile,

    pub fn deinit(self: *LoadedProfile) void {
        self.arena.deinit();
    }
};

/// Load a saved profile by its on-disk filename (as returned by
/// `listProfiles`).
pub fn loadProfile(gpa: Allocator, filename: []const u8) !LoadedProfile {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try profilePathForFilename(arena, filename);
    const content = try readFile(arena, path);
    const profile = try std.json.parseFromSliceLeaky(ProfileFile, arena, content, .{});

    return .{ .arena = arena_state, .profile = profile };
}
