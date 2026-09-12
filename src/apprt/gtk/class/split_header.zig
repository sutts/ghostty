const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;

const Style = configpkg.Config.SplitHeaderStyle;

const log = std.log.scoped(.gtk_ghostty_split_header);

/// How often git information for the working directory is refreshed.
const git_refresh_seconds = 10;

/// Prints the branch, `git diff --numstat` against HEAD, and the number of
/// untracked files for the directory in $1, separated by ASCII record
/// separators. Optional locks are disabled so a background refresh never
/// takes index.lock out from under the user's own git commands.
const git_script =
    \\cd "$1" 2>/dev/null || exit 1
    \\export GIT_OPTIONAL_LOCKS=0
    \\git rev-parse --abbrev-ref HEAD 2>/dev/null || exit 1
    \\printf '\036\n'
    \\git diff --numstat --no-renames HEAD 2>/dev/null
    \\printf '\036\n'
    \\git ls-files --others --exclude-standard 2>/dev/null | wc -l
;

const avatar_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp" };

/// Pixels sampled per axis when deriving the accent color from an avatar.
const accent_sample_grid = 48;
const accent_hue_bins = 36;

/// Name given to the picker's "no avatar" button so it can't be mistaken
/// for an image path.
const no_avatar_name = "none";

/// Header size steps from the -/+ buttons, and how much each step scales
/// the avatar. Text and padding scale through the matching CSS classes.
const size_min: i8 = -2;
const size_max: i8 = 3;
const size_step_scale = 0.12;
const size_classes = [_][:0]const u8{ "size-m2", "size-m1", "size-0", "size-p1", "size-p2", "size-p3" };

var next_style_id: u32 = 0;

// The generated binding types the return value as non-null, but GLib
// returns NULL once the directory is exhausted.
extern fn g_dir_read_name(dir: *glib.Dir) ?[*:0]const u8;

const Hsl = struct { h: f64, s: f64, l: f64 };

const GitStats = struct {
    branch: []const u8,
    files: u64 = 0,
    insertions: u64 = 0,
    deletions: u64 = 0,
    untracked: u64 = 0,
};

/// A header shown above a terminal surface: an avatar, the title, the
/// working directory, and the git branch and diff stats for that directory.
/// Choosing an avatar also styles the header and the surrounding surface
/// outline with a color sampled from the image.
pub const SplitHeader = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitHeader",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const pwd = struct {
            pub const name = "pwd";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("pwd"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };

        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    const Private = struct {
        pwd: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
        title_override: ?[:0]const u8 = null,

        /// The configured style, and a per-split choice from the context
        /// menu that takes precedence over it.
        default_style: Style = .portrait,
        style_override: ?Style = null,

        /// Size step chosen with the -/+ buttons, from size_min to size_max.
        size_step: i8 = 0,

        // Template binds
        style_button: *gtk.Button,
        smaller_button: *gtk.Button,
        larger_button: *gtk.Button,
        avatar_button: *gtk.Button,
        avatar_image: *gtk.Image,
        avatar_fade: *gtk.Widget,
        title_label: *gtk.Label,
        info_row: *gtk.Box,
        rail_row: *gtk.Box,
        git_box: *gtk.Widget,
        pwd_box: *gtk.Widget,
        pwd_label: *gtk.Label,
        branch_box: *gtk.Widget,
        branch_label: *gtk.Label,
        stats_box: *gtk.Widget,
        files_label: *gtk.Label,
        add_label: *gtk.Label,
        del_label: *gtk.Label,
        untracked_label: *gtk.Label,

        /// The avatar picker, rebuilt each time it opens so newly added
        /// images show up.
        picker: ?*gtk.Popover = null,

        /// Styles for the chosen avatar, scoped by `style_class` which is
        /// added to the enclosing surface.
        css_provider: ?*gtk.CssProvider = null,
        style_class_buf: [32]u8 = undefined,
        style_class: [:0]const u8 = "",

        git_timer: ?c_uint = null,
        git_cancellable: ?*gio.Cancellable = null,

        /// Set once disposed so in-flight git callbacks don't touch
        /// template children that no longer exist.
        disposed: bool = false,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();
        priv.style_class = std.fmt.bufPrintZ(
            &priv.style_class_buf,
            "ghostty-avatar-{d}",
            .{next_style_id},
        ) catch unreachable;
        next_style_id +%= 1;

        _ = gobject.Object.signals.notify.connect(self, *Self, propPwd, self, .{ .detail = "pwd" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propTitle, self, .{ .detail = "title" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propTitle, self, .{ .detail = "title-override" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propVisible, self, .{ .detail = "visible" });

        priv.git_timer = glib.timeoutAddSeconds(git_refresh_seconds, onGitTimer, self);

        self.applyStyle();
        self.updateTitle();
        self.updatePwd();
    }

    fn propPwd(_: *Self, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.updatePwd();
    }

    fn propTitle(_: *Self, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.updateTitle();
    }

    fn propVisible(_: *Self, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.refreshGit();
    }

    fn updateTitle(self: *Self) void {
        const priv = self.private();
        priv.title_label.setLabel(priv.title_override orelse priv.title orelse "Terminal");
    }

    fn updatePwd(self: *Self) void {
        const priv = self.private();
        const pwd = priv.pwd orelse {
            priv.pwd_box.setVisible(0);
            self.setGitStats(null);
            return;
        };
        var buf: [4096]u8 = undefined;
        priv.pwd_label.setLabel(shortenHome(&buf, pwd));
        priv.pwd_box.setVisible(1);
        self.refreshGit();
    }

    fn shortenHome(buf: []u8, path: [:0]const u8) [:0]const u8 {
        const home = std.mem.span(glib.getHomeDir());
        if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
        const rest = path[home.len..];
        if (rest.len > 0 and rest[0] != '/') return path;
        return std.fmt.bufPrintZ(buf, "~{s}", .{rest}) catch path;
    }

    //---------------------------------------------------------------
    // Style

    pub fn setDefaultStyle(self: *Self, style: Style) void {
        self.private().default_style = style;
        self.applyStyle();
    }

    pub fn setStyleOverride(self: *Self, style: Style) void {
        self.private().style_override = style;
        self.applyStyle();
    }

    fn applyStyle(self: *Self) void {
        const priv = self.private();
        const style = priv.style_override orelse priv.default_style;
        const root = self.as(gtk.Widget);
        inline for (std.meta.fields(Style)) |field| {
            const class = "style-" ++ field.name;
            if (@field(Style, field.name) == style) {
                root.addCssClass(class);
            } else {
                root.removeCssClass(class);
            }
        }

        const in_rail = style == .rail;
        const from = if (in_rail) priv.info_row else priv.rail_row;
        const to = if (in_rail) priv.rail_row else priv.info_row;
        moveChild(from, to, priv.pwd_box);
        moveChild(from, to, priv.git_box);
        priv.rail_row.as(gtk.Widget).setVisible(@intFromBool(in_rail));

        const base_size: f64 = switch (style) {
            .portrait => 44,
            .banner => 64,
            .rail => 32,
        };
        const scale = 1.0 + size_step_scale * @as(f64, @floatFromInt(priv.size_step));
        priv.avatar_image.setPixelSize(@intFromFloat(@round(base_size * scale)));
        priv.avatar_fade.setVisible(@intFromBool(style == .banner));

        const size_idx: usize = @intCast(priv.size_step - size_min);
        for (size_classes, 0..) |class, i| {
            if (i == size_idx) {
                root.addCssClass(class);
            } else {
                root.removeCssClass(class);
            }
        }
        priv.smaller_button.as(gtk.Widget).setSensitive(@intFromBool(priv.size_step > size_min));
        priv.larger_button.as(gtk.Widget).setSensitive(@intFromBool(priv.size_step < size_max));

        var tip_buf: [64]u8 = undefined;
        const tip = std.fmt.bufPrintZ(&tip_buf, "Header style: {s} (click for next)", .{@tagName(style)}) catch "Change header style";
        priv.style_button.as(gtk.Widget).setTooltipText(tip);
    }

    fn cycleStyleClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const current = priv.style_override orelse priv.default_style;
        const count = std.meta.fields(Style).len;
        self.setStyleOverride(@enumFromInt((@as(usize, @intFromEnum(current)) + 1) % count));
    }

    fn headerSmallerClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.size_step > size_min) priv.size_step -= 1;
        self.applyStyle();
    }

    fn headerLargerClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.size_step < size_max) priv.size_step += 1;
        self.applyStyle();
    }

    fn moveChild(from: *gtk.Box, to: *gtk.Box, child: *gtk.Widget) void {
        const parent = child.getParent() orelse return;
        if (parent != from.as(gtk.Widget)) return;
        // Removing the child drops the box's reference, so hold one across
        // the move.
        _ = child.as(gobject.Object).ref();
        defer child.as(gobject.Object).unref();
        from.remove(child);
        to.append(child);
    }

    //---------------------------------------------------------------
    // Git

    fn onGitTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.refreshGit();
        return 1;
    }

    fn refreshGit(self: *Self) void {
        const priv = self.private();
        if (priv.git_cancellable) |c| {
            c.cancel();
            c.unref();
            priv.git_cancellable = null;
        }
        if (self.as(gtk.Widget).getVisible() == 0) return;
        const pwd = priv.pwd orelse return;

        const launcher = gio.SubprocessLauncher.new(.{
            .stdout_pipe = true,
            .stderr_silence = true,
        });
        defer launcher.unref();

        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", git_script, "sh", pwd.ptr };
        var err: ?*glib.Error = null;
        const subprocess = launcher.spawnv(@ptrCast(&argv), &err) orelse {
            if (err) |e| e.free();
            log.warn("unable to start git status helper", .{});
            return;
        };

        const cancellable = gio.Cancellable.new();
        priv.git_cancellable = cancellable;
        subprocess.communicateUtf8Async(null, cancellable, onGitDone, self.ref());
    }

    fn onGitDone(
        source: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const subprocess = gobject.ext.cast(gio.Subprocess, source orelse return) orelse return;
        defer subprocess.unref();

        var stdout: ?[*:0]u8 = null;
        var err: ?*glib.Error = null;
        const ok = subprocess.communicateUtf8Finish(result, @ptrCast(&stdout), null, &err) != 0;
        defer if (stdout) |s| glib.free(@ptrCast(s));
        if (err) |e| e.free();

        // A failed finish means the refresh was cancelled or superseded.
        if (!ok or self.private().disposed) return;
        if (subprocess.getSuccessful() == 0) {
            self.setGitStats(null);
            return;
        }
        self.setGitStats(parseGitOutput(std.mem.span(stdout orelse return)));
    }

    fn parseGitOutput(out: []const u8) ?GitStats {
        var sections = std.mem.splitSequence(u8, out, "\x1e\n");
        const branch = std.mem.trim(u8, sections.next() orelse return null, " \t\r\n");
        if (branch.len == 0) return null;

        var stats: GitStats = .{ .branch = branch };
        var lines = std.mem.splitScalar(u8, sections.next() orelse "", '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const added = fields.next() orelse continue;
            const deleted = fields.next() orelse continue;
            stats.files += 1;
            // Binary files report "-" for both counts.
            stats.insertions += std.fmt.parseInt(u64, added, 10) catch 0;
            stats.deletions += std.fmt.parseInt(u64, deleted, 10) catch 0;
        }

        const untracked = std.mem.trim(u8, sections.next() orelse "", " \t\r\n");
        stats.untracked = std.fmt.parseInt(u64, untracked, 10) catch 0;
        return stats;
    }

    fn setGitStats(self: *Self, stats_: ?GitStats) void {
        const priv = self.private();
        const stats = stats_ orelse {
            priv.branch_box.setVisible(0);
            priv.stats_box.setVisible(0);
            return;
        };

        var branch_buf: [256]u8 = undefined;
        priv.branch_label.setLabel(std.fmt.bufPrintZ(&branch_buf, "{s}", .{stats.branch}) catch "?");
        priv.branch_box.setVisible(1);
        priv.stats_box.setVisible(1);

        if (stats.files == 0 and stats.untracked == 0) {
            priv.files_label.setLabel("clean");
            priv.files_label.as(gtk.Widget).setVisible(1);
            priv.add_label.as(gtk.Widget).setVisible(0);
            priv.del_label.as(gtk.Widget).setVisible(0);
            priv.untracked_label.as(gtk.Widget).setVisible(0);
            return;
        }
        setCountLabel(priv.files_label, "{s}", stats.files);
        setCountLabel(priv.add_label, "+{s}", stats.insertions);
        setCountLabel(priv.del_label, "−{s}", stats.deletions);
        setCountLabel(priv.untracked_label, "{s} new", stats.untracked);
    }

    fn setCountLabel(label: *gtk.Label, comptime fmt: []const u8, n: u64) void {
        if (n == 0) {
            label.as(gtk.Widget).setVisible(0);
            return;
        }
        var digits_buf: [32]u8 = undefined;
        var text_buf: [64]u8 = undefined;
        const text = std.fmt.bufPrintZ(&text_buf, fmt, .{groupDigits(&digits_buf, n)}) catch return;
        label.setLabel(text);
        label.as(gtk.Widget).setVisible(1);
    }

    fn groupDigits(buf: []u8, n: u64) []const u8 {
        var raw_buf: [24]u8 = undefined;
        const raw = std.fmt.bufPrint(&raw_buf, "{d}", .{n}) catch return "?";
        var len: usize = 0;
        for (raw, 0..) |ch, i| {
            if (i > 0 and (raw.len - i) % 3 == 0) {
                buf[len] = ',';
                len += 1;
            }
            buf[len] = ch;
            len += 1;
        }
        return buf[0..len];
    }

    //---------------------------------------------------------------
    // Avatar

    fn avatarClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showPicker();
    }

    fn avatarDir(buf: []u8) ?[:0]const u8 {
        const config = Application.default().getConfig();
        defer config.unref();
        const configured = config.get().@"split-header-avatar-dir" orelse {
            const config_dir = std.mem.span(glib.getUserConfigDir());
            return std.fmt.bufPrintZ(buf, "{s}/ghostty/avatars", .{config_dir}) catch null;
        };
        if (std.mem.startsWith(u8, configured, "~/")) {
            const home = std.mem.span(glib.getHomeDir());
            return std.fmt.bufPrintZ(buf, "{s}{s}", .{ home, configured[1..] }) catch null;
        }
        return std.fmt.bufPrintZ(buf, "{s}", .{configured}) catch null;
    }

    fn isAvatarFile(name: []const u8) bool {
        for (avatar_extensions) |ext| {
            if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
        }
        return false;
    }

    fn makeChoiceButton(self: *Self, child: *gtk.Widget, name: [:0]const u8, tooltip: [:0]const u8) *gtk.Widget {
        const button = gtk.Button.new();
        button.setChild(child);
        const widget = button.as(gtk.Widget);
        widget.setName(name);
        widget.setTooltipText(tooltip);
        widget.setFocusable(0);
        widget.setCursorFromName("pointer");
        widget.addCssClass("flat");
        widget.addCssClass("avatar-choice");
        _ = gtk.Button.signals.clicked.connect(button, *Self, choiceClicked, self, .{});
        return widget;
    }

    fn showPicker(self: *Self) void {
        const priv = self.private();
        if (priv.picker) |old| {
            old.as(gtk.Widget).unparent();
            priv.picker = null;
        }

        var dir_buf: [4096]u8 = undefined;
        const dir_path = avatarDir(&dir_buf) orelse return;
        var err: ?*glib.Error = null;
        const dir = glib.Dir.open(dir_path, 0, &err) orelse {
            if (err) |e| e.free();
            log.warn("unable to open split header avatar dir {s}", .{dir_path});
            return;
        };
        defer dir.close();

        const flow = gtk.FlowBox.new();
        flow.setSelectionMode(.none);
        flow.setHomogeneous(1);
        flow.setMinChildrenPerLine(5);
        flow.setMaxChildrenPerLine(5);

        const none_icon = gtk.Image.newFromIconName("action-unavailable-symbolic");
        none_icon.setPixelSize(24);
        flow.append(self.makeChoiceButton(none_icon.as(gtk.Widget), no_avatar_name, "No avatar"));

        while (g_dir_read_name(dir)) |name_ptr| {
            const name = std.mem.span(name_ptr);
            if (!isAvatarFile(name)) continue;
            var path_buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            const texture = gdk.Texture.newFromFilename(path, &err) orelse {
                if (err) |e| e.free();
                err = null;
                continue;
            };
            defer texture.unref();
            const image = gtk.Image.newFromPaintable(texture.as(gdk.Paintable));
            image.setPixelSize(48);
            flow.append(self.makeChoiceButton(image.as(gtk.Widget), path, name));
        }

        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.setPropagateNaturalWidth(1);
        scroller.setPropagateNaturalHeight(1);
        scroller.setMaxContentHeight(360);
        // Five 48px columns plus room for the overlay scrollbar, which
        // otherwise covers the last column.
        scroller.setMinContentWidth(340);
        flow.as(gtk.Widget).setMarginEnd(12);
        scroller.setChild(flow.as(gtk.Widget));

        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).addCssClass("split-header-picker");
        // The avatar sits at the split's left edge, so a centred popover would
        // spill out past it; align it to the avatar so it opens rightward.
        popover.as(gtk.Widget).setHalign(.start);
        popover.setChild(scroller.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(priv.avatar_button.as(gtk.Widget));
        priv.picker = popover;
        popover.popup();
    }

    fn choiceClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const name = std.mem.span(button.as(gtk.Widget).getName());
        if (self.private().picker) |p| p.popdown();
        self.setAvatar(if (name.len > 0 and name[0] == '/') name else null);
    }

    fn setAvatar(self: *Self, path_: ?[:0]const u8) void {
        const priv = self.private();
        const path = path_ orelse {
            priv.avatar_image.setFromIconName("avatar-default-symbolic");
            self.applyAccent(null);
            return;
        };
        var err: ?*glib.Error = null;
        const texture = gdk.Texture.newFromFilename(path, &err) orelse {
            if (err) |e| e.free();
            log.warn("unable to load avatar {s}", .{path});
            return;
        };
        defer texture.unref();
        priv.avatar_image.setFromPaintable(texture.as(gdk.Paintable));
        self.applyAccent(sampleAccent(texture));
    }

    fn findSurface(self: *Self) ?*gtk.Widget {
        var widget = self.as(gtk.Widget).getParent();
        while (widget) |w| : (widget = w.getParent()) {
            if (w.hasCssClass("surface") != 0) return w;
        }
        return null;
    }

    fn removeAccentProvider(self: *Self) void {
        const priv = self.private();
        const provider = priv.css_provider orelse return;
        gtk.StyleContext.removeProviderForDisplay(
            self.as(gtk.Widget).getDisplay(),
            provider.as(gtk.StyleProvider),
        );
        provider.unref();
        priv.css_provider = null;
    }

    fn applyAccent(self: *Self, accent_: ?Hsl) void {
        const priv = self.private();
        self.removeAccentProvider();
        const surface = self.findSurface() orelse return;
        const accent = accent_ orelse {
            surface.removeCssClass(priv.style_class);
            return;
        };

        const s = std.math.clamp(accent.s, 0.5, 0.9);
        const acc = hslToRgb(accent.h, s, 0.58);
        const bg = hslToRgb(accent.h, s * 0.45, 0.12);
        const fg = hslToRgb(accent.h, 0.3, 0.95);

        var css_buf: [2048]u8 = undefined;
        const css = std.fmt.bufPrintZ(&css_buf,
            \\.{[cls]s} .split-header {{ background-color: rgb({[br]d},{[bg]d},{[bb]d}); color: rgb({[fr]d},{[fg]d},{[fb]d}); border-bottom-color: rgba({[ar]d},{[ag]d},{[ab]d},0.25); }}
            \\.{[cls]s} .split-header .avatar-button {{ box-shadow: 0 0 0 2px rgb({[ar]d},{[ag]d},{[ab]d}); }}
            \\.{[cls]s} .split-header.style-banner .avatar-button {{ box-shadow: none; }}
            \\.{[cls]s} .split-header.style-banner .avatar-fade {{ background-image: linear-gradient(to right, rgba({[br]d},{[bg]d},{[bb]d},0) 40%, rgb({[br]d},{[bg]d},{[bb]d})); }}
            \\.{[cls]s} .split-header .split-header-rail {{ border-top-color: rgba({[ar]d},{[ag]d},{[ab]d},0.25); }}
            \\.{[cls]s} .split-accent-border {{ border: 2px solid rgba({[ar]d},{[ag]d},{[ab]d},0.35); }}
            \\.{[cls]s}:focus-within .split-accent-border {{ border-color: rgb({[ar]d},{[ag]d},{[ab]d}); }}
        , .{
            .cls = priv.style_class,
            .br = bg[0],
            .bg = bg[1],
            .bb = bg[2],
            .fr = fg[0],
            .fg = fg[1],
            .fb = fg[2],
            .ar = acc[0],
            .ag = acc[1],
            .ab = acc[2],
        }) catch return;

        const provider = gtk.CssProvider.new();
        provider.loadFromString(css);
        gtk.StyleContext.addProviderForDisplay(
            self.as(gtk.Widget).getDisplay(),
            provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 4,
        );
        priv.css_provider = provider;
        surface.addCssClass(priv.style_class);
    }

    //---------------------------------------------------------------
    // Color

    // Hue histogram weighted by saturation^2 * value, so dark grounds, greys
    // and pale highlights don't win; neighbouring bins are blended so a hue
    // straddling a bin edge isn't split in two.
    fn sampleAccent(texture: *gdk.Texture) ?Hsl {
        const width: usize = @intCast(texture.getWidth());
        const height: usize = @intCast(texture.getHeight());
        if (width == 0 or height == 0) return null;

        const stride = width * 4;
        const alloc = std.heap.c_allocator;
        const data = alloc.alloc(u8, stride * height) catch return null;
        defer alloc.free(data);
        // GDK_MEMORY_DEFAULT: premultiplied BGRA byte order on little-endian.
        texture.download(data.ptr, stride);

        var bins = [_][4]f64{.{ 0, 0, 0, 0 }} ** accent_hue_bins;
        const step_x = @max(1, width / accent_sample_grid);
        const step_y = @max(1, height / accent_sample_grid);
        var y: usize = 0;
        while (y < height) : (y += step_y) {
            var x: usize = 0;
            while (x < width) : (x += step_x) {
                const px = data[y * stride + x * 4 ..][0..4];
                const b: f64 = @floatFromInt(px[0]);
                const g: f64 = @floatFromInt(px[1]);
                const r: f64 = @floatFromInt(px[2]);
                const max = @max(r, g, b);
                const min = @min(r, g, b);
                const v = max / 255.0;
                const sat = if (max == 0) 0 else (max - min) / max;
                if (v < 0.22 or sat < 0.3) continue;
                const hue = rgbToHsl(r, g, b).h;
                const idx = @min(accent_hue_bins - 1, @as(usize, @intFromFloat(hue / (360.0 / @as(f64, accent_hue_bins)))));
                const w = sat * sat * v;
                bins[idx][0] += w;
                bins[idx][1] += r * w;
                bins[idx][2] += g * w;
                bins[idx][3] += b * w;
            }
        }

        var best: ?usize = null;
        var best_weight: f64 = 0;
        for (0..accent_hue_bins) |i| {
            const prev = bins[(i + accent_hue_bins - 1) % accent_hue_bins][0];
            const next = bins[(i + 1) % accent_hue_bins][0];
            const weight = bins[i][0] + 0.5 * (prev + next);
            if (weight > best_weight) {
                best_weight = weight;
                best = i;
            }
        }
        const bin = bins[best orelse return null];
        if (bin[0] == 0) return null;
        return rgbToHsl(bin[1] / bin[0], bin[2] / bin[0], bin[3] / bin[0]);
    }

    fn rgbToHsl(r_: f64, g_: f64, b_: f64) Hsl {
        const r = r_ / 255.0;
        const g = g_ / 255.0;
        const b = b_ / 255.0;
        const max = @max(r, g, b);
        const min = @min(r, g, b);
        const l = (max + min) / 2;
        if (max == min) return .{ .h = 0, .s = 0, .l = l };
        const d = max - min;
        const s = if (l > 0.5) d / (2 - max - min) else d / (max + min);
        var h: f64 = undefined;
        if (max == r) {
            h = (g - b) / d + @as(f64, if (g < b) 6 else 0);
        } else if (max == g) {
            h = (b - r) / d + 2;
        } else {
            h = (r - g) / d + 4;
        }
        return .{ .h = h * 60, .s = s, .l = l };
    }

    fn hslToRgb(h: f64, s: f64, l: f64) [3]u8 {
        const a = s * @min(l, 1 - l);
        var out: [3]u8 = undefined;
        for ([_]f64{ 0, 8, 4 }, 0..) |n, i| {
            const k = @mod(n + h / 30, 12);
            const c = l - a * @max(-1, @min(k - 3, 9 - k, 1));
            out[i] = @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255));
        }
        return out;
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.disposed = true;
        if (priv.git_timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove split header git timer", .{});
            }
            priv.git_timer = null;
        }
        if (priv.git_cancellable) |c| {
            c.cancel();
            c.unref();
            priv.git_cancellable = null;
        }
        if (priv.picker) |p| {
            p.as(gtk.Widget).unparent();
            priv.picker = null;
        }
        self.removeAccentProvider();

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        inline for (.{ "pwd", "title", "title_override" }) |field| {
            if (@field(priv, field)) |v| {
                glib.free(@ptrCast(@constCast(v)));
                @field(priv, field) = null;
            }
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-header",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("style_button", .{});
            class.bindTemplateChildPrivate("smaller_button", .{});
            class.bindTemplateChildPrivate("larger_button", .{});
            class.bindTemplateChildPrivate("avatar_button", .{});
            class.bindTemplateChildPrivate("avatar_image", .{});
            class.bindTemplateChildPrivate("avatar_fade", .{});
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("info_row", .{});
            class.bindTemplateChildPrivate("rail_row", .{});
            class.bindTemplateChildPrivate("git_box", .{});
            class.bindTemplateChildPrivate("pwd_box", .{});
            class.bindTemplateChildPrivate("pwd_label", .{});
            class.bindTemplateChildPrivate("branch_box", .{});
            class.bindTemplateChildPrivate("branch_label", .{});
            class.bindTemplateChildPrivate("stats_box", .{});
            class.bindTemplateChildPrivate("files_label", .{});
            class.bindTemplateChildPrivate("add_label", .{});
            class.bindTemplateChildPrivate("del_label", .{});
            class.bindTemplateChildPrivate("untracked_label", .{});

            // Template Callbacks
            class.bindTemplateCallback("avatar_clicked", &avatarClicked);
            class.bindTemplateCallback("cycle_style", &cycleStyleClicked);
            class.bindTemplateCallback("header_smaller", &headerSmallerClicked);
            class.bindTemplateCallback("header_larger", &headerLargerClicked);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.pwd.impl,
                properties.title.impl,
                properties.@"title-override".impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
