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

fn saveInner(app: *Application) !void {
    const gpa = app.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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

    // If we found nothing to save, leave whatever's already on disk alone
    // rather than overwriting it with an empty session. This matters
    // because closing an app's last window saves state right before that
    // window is destroyed (see `Window.saveSessionIfLastWindow`); the main
    // loop then notices zero windows remain and calls `quitNow` again as
    // its own force-quit cleanup, which must not clobber that save with
    // an empty one just because, by then, there's genuinely nothing left
    // to walk.
    if (windows.items.len == 0) {
        log.debug("session state save skipped: no windows with surfaces to save", .{});
        return;
    }

    var total_tabs: usize = 0;
    for (windows.items) |w| total_tabs += w.tabs.len;

    const state: State = .{ .windows = windows.items };
    try writeState(gpa, &state);
    log.info(
        "session state saved: {d} window(s), {d} tab(s)",
        .{ windows.items.len, total_tabs },
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

fn writeState(gpa: Allocator, state: *const State) !void {
    const path = try statePath(gpa);
    defer gpa.free(path);

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
    try file_writer.interface.print("{f}\n", .{std.json.fmt(state.*, .{
        .whitespace = .indent_2,
    })});
    try file_writer.flush();
    try atomic_file.replace(global.io());
}
