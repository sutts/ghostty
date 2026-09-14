const std = @import("std");
const adw = @import("adw");
const cairo = @import("cairo");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const global = @import("../../../global.zig");
const themepkg = @import("../../../config/theme.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const gtk_ext = @import("../ext.zig");
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;

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

/// Prints a single URL: an open pull/merge request for the current branch
/// if the `gh` (GitHub) or `glab` (GitLab) CLI is installed and finds one,
/// otherwise the branch's tree view on whichever host the origin remote is
/// detected to be (hostname containing "gitlab" is treated as GitLab,
/// everything else as GitHub).
const branch_link_script =
    \\cd "$1" 2>/dev/null || exit 1
    \\export GIT_OPTIONAL_LOCKS=0
    \\branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 1
    \\remote=$(git config --get remote.origin.url 2>/dev/null)
    \\[ -z "$remote" ] && exit 1
    \\
    \\url="${remote%.git}"
    \\case "$url" in
    \\  git@*)
    \\    rest="${url#git@}"
    \\    host="${rest%%:*}"
    \\    path="${rest#*:}"
    \\    ;;
    \\  ssh://*)
    \\    rest="${url#ssh://}"
    \\    rest="${rest#*@}"
    \\    host="${rest%%/*}"
    \\    path="${rest#*/}"
    \\    ;;
    \\  *://*)
    \\    rest="${url#*://}"
    \\    host="${rest%%/*}"
    \\    path="${rest#*/}"
    \\    ;;
    \\  *)
    \\    exit 1
    \\    ;;
    \\esac
    \\
    \\case "$host" in
    \\  *gitlab*) provider=gitlab ;;
    \\  *) provider=github ;;
    \\esac
    \\
    \\if [ "$provider" = gitlab ]; then
    \\  fallback="https://$host/$path/-/tree/$branch"
    \\else
    \\  fallback="https://$host/$path/tree/$branch"
    \\fi
    \\
    \\pr_url=""
    \\if [ "$provider" = github ] && command -v gh >/dev/null 2>&1; then
    \\  pr_url=$(gh pr view --json url -q .url 2>/dev/null)
    \\elif [ "$provider" = gitlab ] && command -v glab >/dev/null 2>&1; then
    \\  pr_url=$(glab mr view --output json 2>/dev/null | sed -n 's/.*"web_url"[ \t]*:[ \t]*"\([^"]*\)".*/\1/p')
    \\fi
    \\
    \\if [ -n "$pr_url" ]; then
    \\  echo "$pr_url"
    \\else
    \\  echo "$fallback"
    \\fi
;

/// Script to update the desktop and taskbar application icon.
const set_app_icon_script =
    \\set -e
    \\SRC="$1"
    \\CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
    \\ICON_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
    \\mkdir -p "$CONFIG_DIR"
    \\
    \\if [ -z "$SRC" ] || [ "$SRC" = "--default" ] || [ "$SRC" = "none" ]; then
    \\    rm -f "$CONFIG_DIR/app-icon.png"
    \\    if [ -f "$CONFIG_DIR/icon-backup/com.mitchellh.ghostty.png" ]; then
    \\        for s in 16 32 48 64 128 256 512; do
    \\            cp -f "$CONFIG_DIR/icon-backup/com.mitchellh.ghostty.png" "$ICON_BASE/${s}x${s}/apps/com.mitchellh.ghostty.png" 2>/dev/null || true
    \\        done
    \\    elif [ -d "/usr/share/icons/hicolor" ]; then
    \\        for s in 16 32 48 64 128 256 512 1024; do
    \\            if [ -f "/usr/share/icons/hicolor/${s}x${s}/apps/com.mitchellh.ghostty.png" ]; then
    \\                mkdir -p "$ICON_BASE/${s}x${s}/apps"
    \\                cp -f "/usr/share/icons/hicolor/${s}x${s}/apps/com.mitchellh.ghostty.png" "$ICON_BASE/${s}x${s}/apps/com.mitchellh.ghostty.png" 2>/dev/null || true
    \\            fi
    \\        done
    \\    fi
    \\else
    \\    if [ ! -f "$SRC" ]; then exit 1; fi
    \\    cp -f "$SRC" "$CONFIG_DIR/app-icon.png"
    \\fi
    \\
    \\python3 - "$SRC" "$CONFIG_DIR" "$ICON_BASE" << 'PYEOF' 2>/dev/null || true
    \\import sys, os, subprocess
    \\from PIL import Image
    \\
    \\src = sys.argv[1]
    \\config_dir = sys.argv[2]
    \\icon_base = sys.argv[3]
    \\
    \\is_default = not src or src in ('--default', 'none')
    \\
    \\if not is_default and os.path.isfile(src):
    \\    base_img = Image.open(src).convert('RGBA')
    \\    for s in [16, 32, 48, 64, 128, 256, 512]:
    \\        d = os.path.join(icon_base, f"{s}x{s}", "apps")
    \\        os.makedirs(d, exist_ok=True)
    \\        base_img.resize((s, s), Image.Resampling.LANCZOS).save(os.path.join(d, "com.mitchellh.ghostty.png"), "PNG")
    \\        d2 = os.path.join(icon_base, f"{s}x{s}@2", "apps")
    \\        if os.path.isdir(d2):
    \\            base_img.resize((s, s), Image.Resampling.LANCZOS).save(os.path.join(d2, "com.mitchellh.ghostty.png"), "PNG")
    \\
    \\    try:
    \\        from Xlib import display, Xatom
    \\        data = []
    \\        for size in [16, 32, 48, 128]:
    \\            resized = base_img.resize((size, size), Image.Resampling.LANCZOS)
    \\            data.append(size)
    \\            data.append(size)
    \\            pixels = resized.load()
    \\            for y in range(size):
    \\                for x in range(size):
    \\                    r, g, b, a = pixels[x, y]
    \\                    data.append((a << 24) | (r << 16) | (g << 8) | b)
    \\        d = display.Display()
    \\        net_wm_icon = d.intern_atom('_NET_WM_ICON')
    \\        out = subprocess.check_output(['wmctrl', '-lx']).decode()
    \\        for line in out.splitlines():
    \\            parts = line.split()
    \\            if len(parts) >= 3 and 'ghostty' in parts[2].lower():
    \\                try:
    \\                    w = d.create_resource_object('window', int(parts[0], 16))
    \\                    w.change_property(net_wm_icon, Xatom.CARDINAL, 32, data)
    \\                except Exception:
    \\                    pass
    \\        d.flush()
    \\    except Exception:
    \\        pass
    \\PYEOF
    \\
    \\if [ -n "$SRC" ] && [ "$SRC" != "--default" ] && [ "$SRC" != "none" ]; then
    \\    for s in 16 32 48 64 128 256 512; do
    \\        d="$ICON_BASE/${s}x${s}/apps"
    \\        mkdir -p "$d"
    \\        if command -v convert >/dev/null 2>&1; then
    \\            convert "$SRC" -resize "${s}x${s}" "$d/com.mitchellh.ghostty.png" 2>/dev/null || true
    \\        fi
    \\    done
    \\fi
    \\
    \\if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    \\    gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
    \\elif command -v gtk4-update-icon-cache >/dev/null 2>&1; then
    \\    gtk4-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
    \\fi
    \\
    \\gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon --method org.Cinnamon.ReloadTheme 2>/dev/null || true
;

/// Script to persist the default avatar in the main Ghostty config
/// (config.ghostty, falling back to the older plain "config").
const set_default_avatar_script =
    \\set -e
    \\SRC="$1"
    \\DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
    \\CONF="$DIR/config.ghostty"
    \\if [ ! -f "$CONF" ] && [ -f "$DIR/config" ]; then CONF="$DIR/config"; fi
    \\mkdir -p "$DIR"
    \\if [ -z "$SRC" ] || [ "$SRC" = "none" ]; then
    \\    sed -i '/^[[:space:]]*split-header-default-avatar/d' "$CONF" 2>/dev/null || true
    \\    exit 0
    \\fi
    \\NAME="$(basename "$SRC")"
    \\if grep -q "^[[:space:]]*split-header-default-avatar" "$CONF" 2>/dev/null; then
    \\    sed -i "s|^[[:space:]]*split-header-default-avatar.*|split-header-default-avatar = $NAME|" "$CONF"
    \\else
    \\    echo "split-header-default-avatar = $NAME" >> "$CONF"
    \\fi
;

const avatar_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp" };

/// Pixels sampled per axis when deriving the accent color from an avatar.
const accent_sample_grid = 48;
const accent_hue_bins = 36;

/// Name given to the picker's "no avatar" button so it can't be mistaken
/// for an image path.
const no_avatar_name = "none";

/// Name given to the theme picker's "default" row; the colon keeps it from
/// colliding with a theme file name.
const default_theme_name = ":default";

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
        pub const hostname = struct {
            pub const name = "hostname";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("hostname"),
                },
            );
        };

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
        hostname: ?[:0]const u8 = null,
        pwd: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
        title_override: ?[:0]const u8 = null,

        /// The configured style, and a per-split choice from the context
        /// menu that takes precedence over it.
        default_style: Style = .portrait,
        style_override: ?Style = null,

        /// Size step, from size_min to size_max. It follows the configured
        /// default until the -/+ buttons are used on this split.
        size_step: i8 = 0,
        size_touched: bool = false,

        /// Whether this split is marked dangerous. Purely a runtime, in
        /// memory choice, like style_override; it doesn't survive a config
        /// reload.
        danger: bool = false,
        danger_text_buf: [256]u8 = undefined,

        /// The theme picker, built on first use and kept since the list of
        /// themes doesn't change while running.
        theme_picker: ?*gtk.Popover = null,
        theme_search: ?*gtk.SearchEntry = null,
        theme_list: ?*gtk.ListBox = null,

        default_avatar_idle: ?c_uint = null,

        // Template binds
        expand_button: *gtk.Button,
        danger_button: *gtk.Button,
        danger_strip: *gtk.Widget,
        danger_label: *gtk.Label,
        theme_button: *gtk.Button,
        style_button: *gtk.Button,
        smaller_button: *gtk.Button,
        larger_button: *gtk.Button,
        avatar_button: *gtk.Button,
        avatar_image: *gtk.Image,
        avatar_fade: *gtk.Widget,
        title_button: *gtk.Button,
        title_label: *gtk.Label,
        is_expanded: bool = false,
        info_row: *gtk.Box,
        rail_row: *gtk.Box,
        host_box: *gtk.Widget,
        host_icon: *gtk.Image,
        host_label: *gtk.Label,
        git_box: *gtk.Widget,
        pwd_box: *gtk.Widget,
        pwd_icon: *gtk.Image,
        pwd_label: *gtk.Label,
        branch_box: *gtk.Button,
        branch_label: *gtk.Label,
        stats_box: *gtk.Widget,
        files_label: *gtk.Label,
        add_label: *gtk.Label,
        del_label: *gtk.Label,
        untracked_label: *gtk.Label,

        /// The avatar picker, rebuilt each time it opens so newly added
        /// images show up.
        picker: ?*gtk.Popover = null,

        /// Currently selected avatar path for this split.
        current_avatar_buf: [1024]u8 = undefined,
        current_avatar_path: ?[:0]const u8 = null,

        /// Secondary context popover for choosing app icon or default avatar.
        context_popover: ?*gtk.Popover = null,
        context_avatar_buf: [1024]u8 = undefined,
        context_avatar: ?[:0]const u8 = null,

        /// Styles for the chosen avatar, scoped by `style_class` which is
        /// added to the enclosing surface.
        css_provider: ?*gtk.CssProvider = null,
        style_class_buf: [32]u8 = undefined,
        style_class: [:0]const u8 = "",

        git_timer: ?c_uint = null,
        git_cancellable: ?*gio.Cancellable = null,
        branch_link_cancellable: ?*gio.Cancellable = null,

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

        _ = gobject.Object.signals.notify.connect(self, *Self, propHostname, self, .{ .detail = "hostname" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propPwd, self, .{ .detail = "pwd" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propTitle, self, .{ .detail = "title" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propTitle, self, .{ .detail = "title-override" });
        _ = gobject.Object.signals.notify.connect(self, *Self, propVisible, self, .{ .detail = "visible" });

        priv.git_timer = glib.timeoutAddSeconds(git_refresh_seconds, onGitTimer, self);

        self.applyStyle();

        // During init the header isn't inside its surface yet, so the accent
        // styles for the default avatar would have nothing to attach to.
        priv.default_avatar_idle = glib.idleAdd(onDefaultAvatarIdle, self);

        self.updateTitle();
        self.updateHost();
        self.updatePwd();
    }

    fn propHostname(_: *Self, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.updateHost();
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
        if (priv.danger) self.pushDangerState();
    }

    fn updatePwd(self: *Self) void {
        const priv = self.private();

        // The pwd we track is only ever reported by the local shell (OSC 7
        // reports from a remote host are rejected before reaching us), so
        // once we're SSH'd elsewhere it's stale and would show the wrong
        // directory. Swap it for an SSH badge rather than show a misleading
        // local path.
        if (self.isRemote()) {
            priv.pwd_box.addCssClass("pwd-remote");
            priv.pwd_icon.setFromIconName("network-server-symbolic");
            var buf: [256]u8 = undefined;
            var host_buf: [256]u8 = undefined;
            const label = if (priv.hostname) |host|
                std.fmt.bufPrintZ(&buf, "SSH: {s}", .{shortHostname(&host_buf, host)}) catch "SSH"
            else
                "SSH";
            priv.pwd_label.setLabel(label);
            priv.pwd_box.setVisible(1);
            self.setGitStats(null);
            return;
        }

        priv.pwd_box.removeCssClass("pwd-remote");
        priv.pwd_icon.setFromIconName("folder-symbolic");

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

    fn isRemote(self: *Self) bool {
        const priv = self.private();
        const host: [:0]const u8 = if (priv.hostname) |h| h else std.mem.span(glib.getHostName());
        const local_host = std.mem.span(glib.getHostName());
        return !std.mem.eql(u8, host, local_host);
    }

    fn updateHost(self: *Self) void {
        const priv = self.private();
        const host: [:0]const u8 = if (priv.hostname) |h| h else std.mem.span(glib.getHostName());
        const is_remote = self.isRemote();

        if (is_remote) {
            priv.host_icon.setFromIconName("network-server-symbolic");
            priv.host_box.addCssClass("host-remote");
            var tip_buf: [256]u8 = undefined;
            const tip = std.fmt.bufPrintZ(&tip_buf, "Remote Host (SSH): {s}", .{host}) catch "Remote Host (SSH)";
            priv.host_box.setTooltipText(tip);
        } else {
            priv.host_icon.setFromIconName("computer-symbolic");
            priv.host_box.removeCssClass("host-remote");
            priv.host_box.setTooltipText("Local Host");
        }

        var host_buf: [256]u8 = undefined;
        priv.host_label.setLabel(shortHostname(&host_buf, host));
        priv.host_box.setVisible(1);
    }

    /// Trims a fully-qualified hostname down to just its leading label
    /// (e.g. "cheetah.office.countculture.com" -> "cheetah") so it doesn't
    /// take up excessive space in the header. The full hostname is still
    /// used in tooltips.
    fn shortHostname(buf: []u8, host: [:0]const u8) [:0]const u8 {
        const dot = std.mem.indexOfScalar(u8, host, '.') orelse return host;
        return std.fmt.bufPrintZ(buf, "{s}", .{host[0..dot]}) catch host;
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

    pub fn setDefaultSize(self: *Self, step: i8) void {
        const priv = self.private();
        if (priv.size_touched) return;
        priv.size_step = std.math.clamp(step, size_min, size_max);
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
        moveChild(from, to, priv.host_box);
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
        priv.size_touched = true;
        self.applyStyle();
    }

    fn headerLargerClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.size_step < size_max) priv.size_step += 1;
        priv.size_touched = true;
        self.applyStyle();
    }

    pub fn setExpanded(self: *Self, expanded: bool) void {
        const priv = self.private();
        priv.is_expanded = expanded;
        if (expanded) {
            priv.expand_button.setIconName("view-restore-symbolic");
            priv.expand_button.as(gtk.Widget).setTooltipText("Restore Split (Collapse)");
        } else {
            priv.expand_button.setIconName("view-fullscreen-symbolic");
            priv.expand_button.as(gtk.Widget).setTooltipText("Expand Block (Overlay)");
        }
    }

    fn titleClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self.as(gtk.Widget).activateAction("surface.prompt-title", null);
    }

    fn expandClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        if (self.findSurface()) |surface| {
            _ = surface.grabFocus();
        }
        _ = self.as(gtk.Widget).activateAction("split-tree.expand", null);
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
    // Danger

    fn dangerClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.setDanger(!self.private().danger);
    }

    pub fn setDanger(self: *Self, danger: bool) void {
        self.private().danger = danger;
        self.applyDanger();
    }

    fn applyDanger(self: *Self) void {
        const priv = self.private();
        const root = self.as(gtk.Widget);
        if (priv.danger) {
            root.addCssClass("danger-on");
        } else {
            root.removeCssClass("danger-on");
        }
        priv.danger_strip.setVisible(@intFromBool(priv.danger));
        priv.danger_button.as(gtk.Widget).setTooltipText(
            if (priv.danger) "Dangerous Split (click to clear)" else "Mark Split as Dangerous",
        );
        self.pushDangerState();
    }

    /// Pushes the current danger flag to the enclosing surface: the frame
    /// border around the whole split (a CSS class, same trick as the avatar
    /// accent border) and the tiled watermark over the terminal content
    /// (which needs the actual Surface, since it's driven from code).
    fn pushDangerState(self: *Self) void {
        const priv = self.private();
        const text: ?[:0]const u8 = if (priv.danger) self.updateDangerLabel() else null;
        const widget = self.findSurface() orelse return;
        if (priv.danger) {
            widget.addCssClass("split-danger-on");
        } else {
            widget.removeCssClass("split-danger-on");
        }
        if (gobject.ext.cast(Surface, widget)) |surface| surface.setDangerWatermark(text);
    }

    /// Upper-cases the current title into the danger strip (and returns it
    /// for the watermark), so the warning reads at a glance
    /// ("PROD-DB-PRIMARY" rather than "prod-db-primary").
    fn updateDangerLabel(self: *Self) [:0]const u8 {
        const priv = self.private();
        const text = priv.title_override orelse priv.title orelse "Terminal";
        const n = @min(priv.danger_text_buf.len - 1, text.len);
        for (text[0..n], 0..) |c, i| priv.danger_text_buf[i] = std.ascii.toUpper(c);
        priv.danger_text_buf[n] = 0;
        const result = priv.danger_text_buf[0..n :0];
        priv.danger_label.setLabel(result);
        return result;
    }

    //---------------------------------------------------------------
    // Git

    fn onGitTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        if (gtk_ext.getAncestor(Surface, self.as(gtk.Widget))) |surface| {
            surface.updateHostname();
        }
        self.updateHost();
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
            priv.branch_box.as(gtk.Widget).setVisible(0);
            priv.stats_box.setVisible(0);
            return;
        };

        var branch_buf: [256]u8 = undefined;
        priv.branch_label.setLabel(std.fmt.bufPrintZ(&branch_buf, "{s}", .{stats.branch}) catch "?");
        priv.branch_box.as(gtk.Widget).setVisible(1);
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

    fn branchClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.openBranchLink();
    }

    /// Opens the working directory in the file manager. When SSH'd
    /// elsewhere we don't know the remote directory, so open the remote
    /// host itself over sftp and let the file manager take it from there.
    fn pwdClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (self.isRemote()) {
            const host = priv.hostname orelse return;
            var buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&buf, "sftp://{s}/", .{host}) catch return;
            Application.default().openUrl(.{ .kind = .unknown, .url = url });
            return;
        }
        const pwd = priv.pwd orelse return;
        Application.default().openUrl(.{ .kind = .unknown, .url = pwd });
    }

    fn openBranchLink(self: *Self) void {
        const priv = self.private();
        if (priv.branch_link_cancellable) |c| {
            c.cancel();
            c.unref();
            priv.branch_link_cancellable = null;
        }
        const pwd = priv.pwd orelse return;

        const launcher = gio.SubprocessLauncher.new(.{
            .stdout_pipe = true,
            .stderr_silence = true,
        });
        defer launcher.unref();

        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", branch_link_script, "sh", pwd.ptr };
        var err: ?*glib.Error = null;
        const subprocess = launcher.spawnv(@ptrCast(&argv), &err) orelse {
            if (err) |e| e.free();
            log.warn("unable to start branch link helper", .{});
            return;
        };

        const cancellable = gio.Cancellable.new();
        priv.branch_link_cancellable = cancellable;
        subprocess.communicateUtf8Async(null, cancellable, onBranchLinkDone, self.ref());
    }

    fn onBranchLinkDone(
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

        // A failed finish means the lookup was cancelled or superseded.
        if (!ok or self.private().disposed) return;
        if (subprocess.getSuccessful() == 0) return;

        const url = std.mem.trim(u8, std.mem.span(stdout orelse return), " \t\r\n");
        if (url.len == 0) return;

        Application.default().openUrl(.{ .kind = .unknown, .url = url });
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
            const dir = std.fmt.bufPrintZ(buf, "{s}/ghostty/avatars", .{config_dir}) catch {
                log.warn("avatar dir: default path too long for buffer", .{});
                return null;
            };
            log.info("avatar dir: split-header-avatar-dir unset, using default {s}", .{dir});
            return dir;
        };
        const dir = dir: {
            if (std.mem.startsWith(u8, configured, "~/")) {
                const home = std.mem.span(glib.getHomeDir());
                break :dir std.fmt.bufPrintZ(buf, "{s}{s}", .{ home, configured[1..] }) catch null;
            }
            break :dir std.fmt.bufPrintZ(buf, "{s}", .{configured}) catch null;
        } orelse {
            log.warn("avatar dir: configured path too long for buffer: {s}", .{configured});
            return null;
        };
        const exists = glib.fileTest(dir, .{ .is_dir = true }) != 0;
        log.info("avatar dir: split-header-avatar-dir={s} resolved={s} is_dir={}", .{ configured, dir, exists });
        return dir;
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

        var tip_buf: [512]u8 = undefined;
        const is_none = std.mem.eql(u8, name, no_avatar_name);
        const full_tip = if (is_none)
            std.fmt.bufPrintZ(&tip_buf, "{s}\nLeft-click: Remove split avatar\nRight-click: Options / Reset icon", .{tooltip}) catch tooltip
        else
            std.fmt.bufPrintZ(&tip_buf, "{s}\nLeft-click: Set split avatar\nRight-click: Set as app icon / Options", .{tooltip}) catch tooltip;
        widget.setTooltipText(full_tip);

        widget.setFocusable(0);
        widget.setCursorFromName("pointer");
        widget.addCssClass("flat");
        widget.addCssClass("avatar-choice");
        _ = gtk.Button.signals.clicked.connect(button, *Self, choiceClicked, self, .{});

        const gesture = gtk.GestureClick.new();
        gesture.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(gesture, *Self, choiceRightClicked, self, .{});
        widget.addController(gesture.as(gtk.EventController));

        return widget;
    }

    fn choiceRightClicked(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        const name = std.mem.span(widget.getName());
        self.showAvatarContextMenu(widget, name);
    }

    fn showAvatarContextMenu(self: *Self, widget: *gtk.Widget, path: []const u8) void {
        const priv = self.private();
        if (priv.context_popover) |old| {
            old.as(gtk.Widget).unparent();
            priv.context_popover = null;
        }

        const is_none = std.mem.eql(u8, path, no_avatar_name);
        priv.context_avatar = if (is_none) null else (std.fmt.bufPrintZ(&priv.context_avatar_buf, "{s}", .{path}) catch null);

        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).addCssClass("avatar-context-menu");
        popover.as(gtk.Widget).setParent(widget);

        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setMarginTop(6);
        box.as(gtk.Widget).setMarginBottom(6);
        box.as(gtk.Widget).setMarginStart(6);
        box.as(gtk.Widget).setMarginEnd(6);

        if (is_none) {
            const clear_btn = gtk.Button.newWithLabel("Clear Split Avatar");
            clear_btn.as(gtk.Widget).addCssClass("flat");
            clear_btn.as(gtk.Widget).setHalign(.fill);
            _ = gtk.Button.signals.clicked.connect(clear_btn, *Self, onContextClearSplit, self, .{});
            box.append(clear_btn.as(gtk.Widget));

            const reset_icon_btn = gtk.Button.newWithLabel("Reset Default App Icon");
            reset_icon_btn.as(gtk.Widget).addCssClass("flat");
            reset_icon_btn.as(gtk.Widget).setHalign(.fill);
            _ = gtk.Button.signals.clicked.connect(reset_icon_btn, *Self, onContextResetAppIcon, self, .{});
            box.append(reset_icon_btn.as(gtk.Widget));
        } else {
            // "Set as Desktop App Icon"
            const app_icon_btn = gtk.Button.new();
            app_icon_btn.as(gtk.Widget).addCssClass("flat");
            app_icon_btn.as(gtk.Widget).setHalign(.fill);
            const app_icon_box = gtk.Box.new(.horizontal, 8);
            const app_icon_img = gtk.Image.newFromIconName("emblem-favorite-symbolic");
            const app_icon_lbl = gtk.Label.new("Set as Desktop App Icon");
            app_icon_box.append(app_icon_img.as(gtk.Widget));
            app_icon_box.append(app_icon_lbl.as(gtk.Widget));
            app_icon_btn.setChild(app_icon_box.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(app_icon_btn, *Self, onContextSetAppIcon, self, .{});
            box.append(app_icon_btn.as(gtk.Widget));

            // "Set as Split Avatar"
            const split_btn = gtk.Button.new();
            split_btn.as(gtk.Widget).addCssClass("flat");
            split_btn.as(gtk.Widget).setHalign(.fill);
            const split_box = gtk.Box.new(.horizontal, 8);
            const split_img = gtk.Image.newFromIconName("avatar-default-symbolic");
            const split_lbl = gtk.Label.new("Set as Split Avatar");
            split_box.append(split_img.as(gtk.Widget));
            split_box.append(split_lbl.as(gtk.Widget));
            split_btn.setChild(split_box.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(split_btn, *Self, onContextSetSplitAvatar, self, .{});
            box.append(split_btn.as(gtk.Widget));

            // "Set as Default Split Avatar"
            const default_btn = gtk.Button.new();
            default_btn.as(gtk.Widget).addCssClass("flat");
            default_btn.as(gtk.Widget).setHalign(.fill);
            const def_box = gtk.Box.new(.horizontal, 8);
            const def_img = gtk.Image.newFromIconName("preferences-desktop-appearance-symbolic");
            const def_lbl = gtk.Label.new("Set as Default Split Avatar");
            def_box.append(def_img.as(gtk.Widget));
            def_box.append(def_lbl.as(gtk.Widget));
            default_btn.setChild(def_box.as(gtk.Widget));
            _ = gtk.Button.signals.clicked.connect(default_btn, *Self, onContextSetDefaultAvatar, self, .{});
            box.append(default_btn.as(gtk.Widget));
        }

        popover.setChild(box.as(gtk.Widget));
        priv.context_popover = popover;
        popover.popup();
    }

    fn onContextClearSplit(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.context_popover) |p| p.popdown();
        if (priv.picker) |p| p.popdown();
        self.setAvatar(null);
    }

    fn onContextResetAppIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.context_popover) |p| p.popdown();
        if (priv.picker) |p| p.popdown();
        self.setAsAppIcon(null);
    }

    fn onContextSetAppIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.context_popover) |p| p.popdown();
        if (priv.picker) |p| p.popdown();
        self.setAsAppIcon(priv.context_avatar);
    }

    fn onContextSetSplitAvatar(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.context_popover) |p| p.popdown();
        if (priv.picker) |p| p.popdown();
        self.setAvatar(priv.context_avatar);
    }

    fn onContextSetDefaultAvatar(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.context_popover) |p| p.popdown();
        if (priv.picker) |p| p.popdown();
        const target = priv.context_avatar;
        self.setAvatar(target);
        self.saveDefaultAvatar(target);
    }

    fn onSetCurrentAsAppIcon(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.picker) |p| p.popdown();
        self.setAsAppIcon(priv.current_avatar_path);
    }

    fn saveDefaultAvatar(self: *Self, path_: ?[:0]const u8) void {
        const launcher = gio.SubprocessLauncher.new(.{
            .stdout_pipe = true,
            .stderr_silence = true,
        });
        defer launcher.unref();

        const path_arg: [:0]const u8 = if (path_) |p| p else "";
        log.info("default avatar: saving split-header-default-avatar={s} to main config", .{path_arg});
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", set_default_avatar_script, "sh", path_arg.ptr };
        var err: ?*glib.Error = null;
        const subprocess = launcher.spawnv(@ptrCast(&argv), &err) orelse {
            if (err) |e| e.free();
            log.warn("unable to run set-default-avatar helper", .{});
            return;
        };
        defer subprocess.unref();

        const root = self.as(gtk.Widget).getRoot();
        if (root) |r| {
            if (gobject.ext.cast(Window, r)) |w| {
                w.addToast("Saved as default split avatar");
            }
        }
    }

    fn setAsAppIcon(self: *Self, path_: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.context_popover) |p| p.popdown();
        if (priv.picker) |p| p.popdown();

        const launcher = gio.SubprocessLauncher.new(.{
            .stdout_pipe = true,
            .stderr_silence = true,
        });
        defer launcher.unref();

        const path_arg: [:0]const u8 = if (path_) |p| p else "";
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", set_app_icon_script, "sh", path_arg.ptr };
        var err: ?*glib.Error = null;
        const subprocess = launcher.spawnv(@ptrCast(&argv), &err) orelse {
            if (err) |e| e.free();
            log.warn("unable to run set-app-icon helper", .{});
            return;
        };
        defer subprocess.unref();

        const root = self.as(gtk.Widget).getRoot();
        if (root) |r| {
            if (gobject.ext.cast(Window, r)) |w| {
                if (path_ != null and !std.mem.eql(u8, path_.?, no_avatar_name)) {
                    w.addToast("Desktop application icon updated");
                } else {
                    w.addToast("Desktop application icon reset to default");
                }
            }
        }
    }

    fn showPicker(self: *Self) void {
        const priv = self.private();
        if (priv.context_popover) |old| {
            old.as(gtk.Widget).unparent();
            priv.context_popover = null;
        }
        if (priv.picker) |old| {
            old.as(gtk.Widget).unparent();
            priv.picker = null;
        }

        var dir_buf: [4096]u8 = undefined;
        const dir_path = avatarDir(&dir_buf) orelse {
            log.warn("avatar picker: no avatar dir could be resolved", .{});
            return;
        };
        var err: ?*glib.Error = null;
        const dir = glib.Dir.open(dir_path, 0, &err) orelse {
            log.warn("avatar picker: unable to open avatar dir {s}: {s}", .{
                dir_path,
                if (err) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error",
            });
            if (err) |e| e.free();
            return;
        };
        defer dir.close();
        log.info("avatar picker: listing {s}", .{dir_path});

        const flow = gtk.FlowBox.new();
        flow.setSelectionMode(.none);
        flow.setHomogeneous(1);
        flow.setMinChildrenPerLine(8);
        flow.setMaxChildrenPerLine(8);

        const none_icon = gtk.Image.newFromIconName("action-unavailable-symbolic");
        none_icon.setPixelSize(24);
        flow.append(self.makeChoiceButton(none_icon.as(gtk.Widget), no_avatar_name, "No avatar"));

        var seen: usize = 0;
        var loaded: usize = 0;
        while (g_dir_read_name(dir)) |name_ptr| {
            const name = std.mem.span(name_ptr);
            seen += 1;
            if (!isAvatarFile(name)) {
                log.debug("avatar picker: skipping {s} (not an image extension)", .{name});
                continue;
            }
            var path_buf: [4096]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, name }) catch {
                log.warn("avatar picker: path too long, skipping {s}", .{name});
                continue;
            };
            const texture = gdk.Texture.newFromFilename(path, &err) orelse {
                log.warn("avatar picker: unable to load {s}: {s}", .{
                    path,
                    if (err) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error",
                });
                if (err) |e| e.free();
                err = null;
                continue;
            };
            defer texture.unref();
            loaded += 1;
            log.debug("avatar picker: loaded {s}", .{path});
            const image = gtk.Image.newFromPaintable(texture.as(gdk.Paintable));
            image.setPixelSize(48);
            flow.append(self.makeChoiceButton(image.as(gtk.Widget), path, name));
        }
        log.info("avatar picker: {d} entries in {s}, {d} avatars loaded", .{ seen, dir_path, loaded });

        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.setPropagateNaturalWidth(1);
        scroller.setPropagateNaturalHeight(1);
        scroller.setMaxContentHeight(420);
        // Eight 48px columns plus room for the overlay scrollbar, which
        // otherwise covers the last column.
        scroller.setMinContentWidth(540);
        flow.as(gtk.Widget).setMarginEnd(12);
        scroller.setChild(flow.as(gtk.Widget));

        const container = gtk.Box.new(.vertical, 8);
        container.as(gtk.Widget).setMarginTop(8);
        container.as(gtk.Widget).setMarginBottom(8);
        container.as(gtk.Widget).setMarginStart(10);
        container.as(gtk.Widget).setMarginEnd(10);

        // Header
        const header_row = gtk.Box.new(.horizontal, 8);
        const title_box = gtk.Box.new(.vertical, 2);

        const title_label = gtk.Label.new("Choose Avatar");
        title_label.as(gtk.Widget).addCssClass("title-4");
        title_label.as(gtk.Widget).setHalign(.start);

        const subtitle_label = gtk.Label.new("Click to select · Right-click for options");
        subtitle_label.as(gtk.Widget).addCssClass("dim-label");
        subtitle_label.as(gtk.Widget).addCssClass("caption");
        subtitle_label.as(gtk.Widget).setHalign(.start);

        title_box.append(title_label.as(gtk.Widget));
        title_box.append(subtitle_label.as(gtk.Widget));
        header_row.append(title_box.as(gtk.Widget));

        // Spacer
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        header_row.append(spacer.as(gtk.Widget));

        // Button: "Set as App Icon"
        const current_app_icon_btn = gtk.Button.new();
        current_app_icon_btn.as(gtk.Widget).addCssClass("flat");
        current_app_icon_btn.as(gtk.Widget).setTooltipText("Set current split avatar as desktop / taskbar icon");
        const btn_content = gtk.Box.new(.horizontal, 6);
        const btn_icon = gtk.Image.newFromIconName("emblem-favorite-symbolic");
        const btn_lbl = gtk.Label.new("Set as App Icon");
        btn_content.append(btn_icon.as(gtk.Widget));
        btn_content.append(btn_lbl.as(gtk.Widget));
        current_app_icon_btn.setChild(btn_content.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(current_app_icon_btn, *Self, onSetCurrentAsAppIcon, self, .{});
        header_row.append(current_app_icon_btn.as(gtk.Widget));

        container.append(header_row.as(gtk.Widget));
        container.append(scroller.as(gtk.Widget));

        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).addCssClass("split-header-picker");
        // The avatar sits at the split's left edge, so a centred popover would
        // spill out past it; align it to the avatar so it opens rightward.
        popover.as(gtk.Widget).setHalign(.start);
        popover.setChild(container.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(priv.avatar_button.as(gtk.Widget));
        priv.picker = popover;
        popover.popup();
    }

    fn onDefaultAvatarIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.private().default_avatar_idle = null;
        self.loadDefaultAvatar();
        return 0;
    }

    fn loadDefaultAvatar(self: *Self) void {
        const config = Application.default().getConfig();
        defer config.unref();
        const name = config.get().@"split-header-default-avatar" orelse {
            log.info("default avatar: split-header-default-avatar unset, using placeholder icon", .{});
            return;
        };
        var dir_buf: [4096]u8 = undefined;
        const dir = avatarDir(&dir_buf) orelse {
            log.warn("default avatar: no avatar dir could be resolved for {s}", .{name});
            return;
        };
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch {
            log.warn("default avatar: path too long for {s}/{s}", .{ dir, name });
            return;
        };
        if (glib.fileTest(path, .{ .is_regular = true }) == 0) {
            log.warn("default avatar: {s} does not exist or is not a regular file", .{path});
            return;
        }
        log.info("default avatar: loading {s}", .{path});
        self.setAvatar(path);
    }

    fn choiceClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const name = std.mem.span(button.as(gtk.Widget).getName());
        if (self.private().picker) |p| p.popdown();
        self.setAvatar(if (name.len > 0 and name[0] == '/') name else null);
    }

    fn setAvatar(self: *Self, path_: ?[:0]const u8) void {
        const priv = self.private();
        if (path_) |p| {
            priv.current_avatar_path = std.fmt.bufPrintZ(&priv.current_avatar_buf, "{s}", .{p}) catch null;
        } else {
            priv.current_avatar_path = null;
        }
        const path = path_ orelse {
            log.debug("set avatar: cleared, using placeholder icon", .{});
            priv.avatar_image.setFromIconName("avatar-default-symbolic");
            self.applyAccent(null);
            return;
        };
        var err: ?*glib.Error = null;
        const texture = gdk.Texture.newFromFilename(path, &err) orelse {
            log.warn("set avatar: unable to load {s}: {s}", .{
                path,
                if (err) |e| std.mem.span(e.f_message orelse "unknown error") else "unknown error",
            });
            if (err) |e| e.free();
            return;
        };
        defer texture.unref();
        log.info("set avatar: loaded {s} ({d}x{d})", .{ path, texture.getWidth(), texture.getHeight() });
        priv.avatar_image.setFromPaintable(texture.as(gdk.Paintable));
        self.applyAccent(sampleAccent(texture));
    }

    //---------------------------------------------------------------
    // Theme

    fn themeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.showThemePicker();
    }

    fn showThemePicker(self: *Self) void {
        const priv = self.private();
        if (priv.theme_picker) |popover| {
            popover.popup();
            return;
        }

        const list = gtk.ListBox.new();
        list.setSelectionMode(.none);
        list.setActivateOnSingleClick(1);
        list.append(makeThemeRow(default_theme_name, "Default (from config)", null));
        appendThemeRows(list);
        list.setFilterFunc(themeFilter, self, null);
        _ = gtk.ListBox.signals.row_activated.connect(list, *Self, themeRowActivated, self, .{});

        const search = gtk.SearchEntry.new();
        _ = gtk.SearchEntry.signals.search_changed.connect(search, *Self, themeSearchChanged, self, .{});

        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.setPropagateNaturalHeight(1);
        scroller.setMaxContentHeight(360);
        scroller.setMinContentWidth(240);
        scroller.setChild(list.as(gtk.Widget));

        const box = gtk.Box.new(.vertical, 6);
        box.append(search.as(gtk.Widget));
        box.append(scroller.as(gtk.Widget));

        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).addCssClass("split-header-theme-picker");
        popover.setChild(box.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(priv.theme_button.as(gtk.Widget));
        // The button sits at the right edge of the split, so align the
        // popover's right edge to it and let it open leftward.
        popover.as(gtk.Widget).setHalign(.end);

        priv.theme_picker = popover;
        priv.theme_search = search;
        priv.theme_list = list;
        popover.popup();
        _ = search.as(gtk.Widget).grabFocus();
    }

    fn makeThemeRow(value: [:0]const u8, text: [:0]const u8, swatch: ?*Swatch) *gtk.Widget {
        const box = gtk.Box.new(.horizontal, 10);
        const box_widget = box.as(gtk.Widget);
        box_widget.setMarginStart(8);
        box_widget.setMarginEnd(8);
        box_widget.setMarginTop(4);
        box_widget.setMarginBottom(4);

        // Every row gets a swatch-sized slot so the names stay aligned even
        // for the "default" row and themes that failed to parse.
        const area = gtk.DrawingArea.new();
        area.setContentWidth(Swatch.width);
        area.setContentHeight(Swatch.height);
        area.as(gtk.Widget).setValign(.center);
        if (swatch) |sw| area.setDrawFunc(swatchDraw, sw, Swatch.destroy);
        box.append(area.as(gtk.Widget));

        const label = gtk.Label.new(text);
        label.setXalign(0);
        label.setEllipsize(.end);
        box.append(label.as(gtk.Widget));

        const row = gtk.ListBoxRow.new();
        row.setChild(box_widget);
        row.as(gtk.Widget).setName(value);
        return row.as(gtk.Widget);
    }

    /// The colors shown next to a theme in the picker, read straight from
    /// the theme file so we don't pay for a full config parse per theme.
    const Swatch = struct {
        const width: c_int = 84;
        const height: c_int = 20;

        bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
        fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
        palette: [8]?Rgb = .{null} ** 8,

        const Rgb = struct { r: u8, g: u8, b: u8 };

        /// Parses `key = value` lines, keeping only the colors the swatch
        /// draws. Returns null if the file has no background at all since
        /// then it isn't really a theme we can preview.
        fn parse(text: []const u8) ?Swatch {
            var sw: Swatch = .{};
            var have_bg = false;
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (std.mem.eql(u8, key, "background")) {
                    sw.bg = parseHex(value) orelse continue;
                    have_bg = true;
                } else if (std.mem.eql(u8, key, "foreground")) {
                    sw.fg = parseHex(value) orelse continue;
                } else if (std.mem.eql(u8, key, "palette")) {
                    const peq = std.mem.indexOfScalar(u8, value, '=') orelse continue;
                    const idx = std.fmt.parseInt(u8, std.mem.trim(u8, value[0..peq], " \t"), 10) catch continue;
                    if (idx >= sw.palette.len) continue;
                    sw.palette[idx] = parseHex(std.mem.trim(u8, value[peq + 1 ..], " \t"));
                }
            }
            return if (have_bg) sw else null;
        }

        fn parseHex(value: []const u8) ?Rgb {
            const hex = if (std.mem.startsWith(u8, value, "#")) value[1..] else value;
            if (hex.len != 6) return null;
            const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
            const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
            const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
            return .{ .r = r, .g = g, .b = b };
        }

        fn create(text: []const u8) ?*Swatch {
            const sw = parse(text) orelse return null;
            const ptr = std.heap.c_allocator.create(Swatch) catch return null;
            ptr.* = sw;
            return ptr;
        }

        fn destroy(ud: ?*anyopaque) callconv(.c) void {
            const ptr: *Swatch = @ptrCast(@alignCast(ud orelse return));
            std.heap.c_allocator.destroy(ptr);
        }
    };

    fn setSource(cr: *cairo.Context, c: Swatch.Rgb) void {
        cr.setSourceRgb(
            @as(f64, @floatFromInt(c.r)) / 255.0,
            @as(f64, @floatFromInt(c.g)) / 255.0,
            @as(f64, @floatFromInt(c.b)) / 255.0,
        );
    }

    /// A rounded rectangle of the theme background holding a "text" bar in
    /// the foreground color and dots for palette 1-6 (red through cyan),
    /// which is enough to tell themes apart at a glance.
    fn swatchDraw(
        _: *gtk.DrawingArea,
        cr: *cairo.Context,
        width: c_int,
        height: c_int,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const sw: *Swatch = @ptrCast(@alignCast(ud orelse return));
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const radius: f64 = 4;
        const pi: f64 = std.math.pi;

        cr.newSubPath();
        cr.arc(w - radius, radius, radius, -pi / 2, 0);
        cr.arc(w - radius, h - radius, radius, 0, pi / 2);
        cr.arc(radius, h - radius, radius, pi / 2, pi);
        cr.arc(radius, radius, radius, pi, 3 * pi / 2);
        cr.closePath();
        setSource(cr, sw.bg);
        cr.fillPreserve();
        cr.setSourceRgba(0.5, 0.5, 0.5, 0.35);
        cr.setLineWidth(1);
        cr.stroke();

        // Two short "lines of text" in the foreground color.
        setSource(cr, sw.fg);
        cr.rectangle(7, h / 2 - 4, 14, 2.5);
        cr.rectangle(7, h / 2 + 1.5, 9, 2.5);
        cr.fill();

        var x: f64 = 32;
        for (sw.palette[1..7]) |maybe| {
            if (maybe) |c| {
                setSource(cr, c);
                cr.arc(x, h / 2, 3, 0, 2 * pi);
                cr.fill();
            }
            x += 8;
        }
    }

    fn appendThemeRows(list: *gtk.ListBox) void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const Entry = struct {
            name: [:0]const u8,
            swatch: ?*Swatch,

            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };

        var entries: std.ArrayList(Entry) = .empty;
        var it: themepkg.LocationIterator = .{ .arena_alloc = alloc };
        while (it.next() catch null) |loc| {
            var dir = std.Io.Dir.cwd().openDir(global.io(), loc.dir, .{ .iterate = true }) catch continue;
            defer dir.close(global.io());
            var walker = dir.iterate();
            while (walker.next(global.io()) catch null) |entry| {
                switch (entry.kind) {
                    .file, .sym_link => {},
                    else => continue,
                }
                if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
                // User themes are listed first and shadow bundled ones of the
                // same name, matching how themes are resolved.
                if (containsName(entries.items, entry.name)) continue;
                const name = alloc.dupeZ(u8, entry.name) catch continue;
                // Theme files are a few hundred bytes; anything huge isn't
                // a theme and just gets no swatch.
                const swatch: ?*Swatch = if (dir.readFileAlloc(global.io(), entry.name, alloc, .limited(64 * 1024))) |text|
                    Swatch.create(text)
                else |_|
                    null;
                entries.append(alloc, .{ .name = name, .swatch = swatch }) catch continue;
            }
        }

        std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
        for (entries.items) |e| list.append(makeThemeRow(e.name, e.name, e.swatch));
    }

    fn containsName(entries: anytype, name: []const u8) bool {
        for (entries) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return true;
        }
        return false;
    }

    fn themeFilter(row: *gtk.ListBoxRow, ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 1));
        const search = self.private().theme_search orelse return 1;
        const query = std.mem.span(search.as(gtk.Editable).getText());
        if (query.len == 0) return 1;
        const name = std.mem.span(row.as(gtk.Widget).getName());
        return @intFromBool(std.ascii.findIgnoreCase(name, query) != null);
    }

    fn themeSearchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        if (self.private().theme_list) |list| list.invalidateFilter();
    }

    fn themeRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const priv = self.private();
        const name = std.mem.span(row.as(gtk.Widget).getName());
        const theme: [:0]const u8 = if (std.mem.eql(u8, name, default_theme_name)) "" else name;
        if (priv.theme_picker) |p| p.popdown();
        _ = self.as(gtk.Widget).activateActionVariant(
            "surface.split-theme",
            glib.Variant.newString(theme),
        );

        var tip_buf: [256]u8 = undefined;
        const tip: [:0]const u8 = if (theme.len == 0)
            "Terminal theme: from config"
        else
            std.fmt.bufPrintZ(&tip_buf, "Terminal theme: {s}", .{theme}) catch "Terminal theme";
        priv.theme_button.as(gtk.Widget).setTooltipText(tip);
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
        if (priv.branch_link_cancellable) |c| {
            c.cancel();
            c.unref();
            priv.branch_link_cancellable = null;
        }
        if (priv.context_popover) |p| {
            p.as(gtk.Widget).unparent();
            priv.context_popover = null;
        }
        if (priv.picker) |p| {
            p.as(gtk.Widget).unparent();
            priv.picker = null;
        }
        if (priv.theme_picker) |p| {
            p.as(gtk.Widget).unparent();
            priv.theme_picker = null;
            priv.theme_search = null;
            priv.theme_list = null;
        }
        if (priv.default_avatar_idle) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove split header default avatar idler", .{});
            }
            priv.default_avatar_idle = null;
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
        inline for (.{ "hostname", "pwd", "title", "title_override" }) |field| {
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
            class.bindTemplateChildPrivate("expand_button", .{});
            class.bindTemplateChildPrivate("danger_button", .{});
            class.bindTemplateChildPrivate("danger_strip", .{});
            class.bindTemplateChildPrivate("danger_label", .{});
            class.bindTemplateChildPrivate("theme_button", .{});
            class.bindTemplateChildPrivate("style_button", .{});
            class.bindTemplateChildPrivate("smaller_button", .{});
            class.bindTemplateChildPrivate("larger_button", .{});
            class.bindTemplateChildPrivate("avatar_button", .{});
            class.bindTemplateChildPrivate("avatar_image", .{});
            class.bindTemplateChildPrivate("avatar_fade", .{});
            class.bindTemplateChildPrivate("title_button", .{});
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("info_row", .{});
            class.bindTemplateChildPrivate("rail_row", .{});
            class.bindTemplateChildPrivate("host_box", .{});
            class.bindTemplateChildPrivate("host_icon", .{});
            class.bindTemplateChildPrivate("host_label", .{});
            class.bindTemplateChildPrivate("git_box", .{});
            class.bindTemplateChildPrivate("pwd_box", .{});
            class.bindTemplateChildPrivate("pwd_icon", .{});
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
            class.bindTemplateCallback("danger_clicked", &dangerClicked);
            class.bindTemplateCallback("theme_clicked", &themeClicked);
            class.bindTemplateCallback("cycle_style", &cycleStyleClicked);
            class.bindTemplateCallback("header_smaller", &headerSmallerClicked);
            class.bindTemplateCallback("header_larger", &headerLargerClicked);
            class.bindTemplateCallback("title_clicked", &titleClicked);
            class.bindTemplateCallback("branch_clicked", &branchClicked);
            class.bindTemplateCallback("pwd_clicked", &pwdClicked);
            class.bindTemplateCallback("expand_clicked", &expandClicked);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.hostname.impl,
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
