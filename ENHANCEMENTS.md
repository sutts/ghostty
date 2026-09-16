# Ghostty · Sutts Build

This branch (`feature/split-header`) is a fork of [Ghostty](https://ghostty.org)
that adds a per-split header, per-split theming, session persistence and a few
other quality-of-life additions to the Linux (GTK) app. Everything here is
Linux only; the macOS app is untouched.

The About dialog identifies the build as **Ghostty · Sutts Build**, and
`ghostty +version` on an installed build reports the upstream version plus
the branch and commit it was built from.

**At a glance**

![The split header, with numbered callouts](images/enhancements/split-header.png)

1 [avatar](#avatars) · 2 title (click to rename) · 3 host pill ([SSH](#ssh)) ·
4 [folder pill](#folder) · 5 header controls ([expand](#expand),
[warning](#warnings), [theme](#themes), style, − / +, [menu](#header-menu)) ·
6 [branch pill](#gitlab) · 7 [git status](#difftool) (click to diff against main)

- [**Split headers**](#split-header) – a strip above every split with avatar, title, folder, host and git status.
- [**Avatars**](#avatars) – pick an image per split; it tints the header and outline, and can become the app icon.
- [**Folder**](#folder) – click the working directory to open it in your file manager.
- [**GitLab / GitHub**](#gitlab) – click the branch to open its PR/MR, or the branch page.
- [**Diff tool**](#difftool) – click the git status counts to open `git difftool --dir-diff main`.
- [**SSH**](#ssh) – remote sessions show a host badge and open over sftp.
- [**Expand**](#expand) – pop a split out into a centred overlay.
- [**Warnings**](#warnings) – mark a split dangerous: red banner, frame and watermark.
- [**Themes**](#themes) – a different Ghostty theme per split, with colour swatches.
- [**Sessions**](#session-save-and-restore-linux) – windows, tabs, splits and folders come back after a quit.
- [**Profiles**](#named-profiles) – save a layout by name and restore it later.
- [**Build & install**](#building-and-installing) – dependencies and the one-line install script.
- [**Coolicons**](#avatars-the-coolicons-collection) – 46 ready-made avatars from GitLab.
- [**Config**](#configuration) – every option explained.

---

## Features

### Split header

Every terminal surface (each split, or the single pane in a tab) gets a
header strip above it. It is enabled by default in this build
(`split-header = true`) and can be turned off in the config.

The header shows, left to right:

- <a id="avatars"></a>**Avatar.** Click it to open a picker listing every PNG, JPEG and WebP
  image in the avatar directory (see `split-header-avatar-dir`). The
  chosen image tints the header and draws a matching outline around the
  surface, brighter when the split has focus. Right-clicking an avatar in
  the picker gives three options:
  - *Set as Split Avatar* – use it for this split only.
  - *Set as Default Split Avatar* – use it for this split and write
    `split-header-default-avatar = <file>` into your main config so every
    new split starts with it.
  - *Set as Desktop App Icon* – resize it into all standard icon sizes
    under `~/.local/share/icons/hicolor` so Ghostty's launcher and taskbar
    entries use it. A copy is kept at `~/.config/ghostty/app-icon.png` so
    the install script can re-apply it after a rebuild. Choosing the
    "none" entry restores the stock icon.
- **Title.** Click it to rename the split.
- <a id="folder"></a>**Working directory pill.** Reported by shell integration (OSC 7).
  Clicking it opens the directory in your file manager. When the shell
  is SSH'd to another machine the pill changes to an **SSH: host** badge
  (the local path would be stale), and clicking it opens the remote host
  over `sftp://`.
- <a id="ssh"></a>**Hostname pill.** Shows the short hostname of the foreground process.
  Remote sessions get a server icon and cyan styling; the full hostname
  is in the tooltip.
- <a id="gitlab"></a>**Git pill.** The current branch plus changed-file, added-line,
  deleted-line and untracked counts, refreshed every 10 seconds by a
  background `git` process. Only shown for local paths inside a
  repository. Clicking the branch opens the open PR/MR for the branch on
  GitHub or GitLab (detected from the `origin` remote, using the `gh` or
  `glab` CLI if installed) or falls back to the branch's tree view.
- <a id="difftool"></a>**Git status counts.** Clicking the changed/added/deleted
  counts runs `git difftool --dir-diff --no-prompt main` in the split's
  directory, so your configured difftool (`diff.guitool`, falling back to
  `diff.tool`) opens with the whole working tree compared against `main`.
  If there is no `main` it tries `master`, then whatever `origin/HEAD`
  points at. A toast explains the failure if no difftool is configured or
  no base branch can be found. Local directories only. Set
  `split-header-diff-command` to run something else instead, such as
  `smerge .` for Sublime Merge, which cannot diff directories.

Header controls sit on the title row and stay dimmed until you hover the
header:

| Control | What it does |
|---|---|
| <a id="expand"></a>Expand | Pops this split out into a centred overlay over a dimmed backdrop. Click again to collapse. |
| <a id="warnings"></a>Warning triangle | Marks the split as **dangerous**: a red banner using the split title, a red frame, and the title tiled diagonally across the terminal as a watermark. Useful for production shells. Runtime only, not persisted. |
| <a id="themes"></a>Theme | Opens a searchable list of every installed Ghostty theme with a colour swatch for each. Picking one applies it to this split only; the override survives config reloads and light/dark switches. |
| Style | Cycles the header layout between `portrait`, `banner` and `rail`. |
| − / + | Shrink or grow this split's header (avatar, text and padding scale together) from two steps below to three above the default. |
| <a id="header-menu"></a>Menu | Opens the same menu as right-clicking the terminal, for when you would rather not right-click into a split to reach it. |

![A split marked dangerous: red banner, red frame and tiled watermark](images/enhancements/danger-split.png)

*A split marked dangerous with the warning triangle: the title becomes a
red banner, the surface gets a red frame, and the title is tiled across
the terminal as a watermark.*

The right-click context menu on a terminal also has a **Header Style**
submenu (Portrait / Banner / Rail). Choosing one shows the header if it
was hidden. The header's menu button opens that same menu: it is the one
menu model rather than a copy, so the two can never drift apart.

Headers use a little extra padding around the terminal content, so the
default window padding was raised from 2 to 4 points to keep text off the
accent border.

### Session save and restore (Linux)

Upstream `window-save-state` only works on macOS. This build implements it
for GTK. With `window-save-state = always`, a clean quit (Quit, or closing
the last window) writes every window's size, maximised state, active tab,
tab list, split layout and ratios, and each split's working directory to:

```
~/.local/state/ghostty/session.json
```

On the next launch the windows, tabs and splits are rebuilt from that file
and each shell starts in its saved directory. Window position is not
restored because GTK does not let apps position their own windows. A
forced kill does not save. Avatars, per-split themes and the danger flag
are not part of the saved state.

### Named profiles

Two entries in the terminal context menu let you snapshot and recall a
layout on demand, independent of `window-save-state`:

- **Save Profile…** prompts for a name and writes the same kind of
  snapshot to `~/.local/state/ghostty/profiles/<name>.json`.
- **Restore Profile…** offers a dropdown of saved names and opens the
  saved windows alongside whatever is already open.

---

## Building and installing

### Dependencies

The fork wraps `zig build`, so it needs everything upstream Ghostty needs
to build from a Git checkout. The full list lives in `nix/devShell.nix`;
the essentials are:

- **zig** at the version pinned by `minimum_zig_version` in
  `build.zig.zon` (0.16.0 at the time of writing). Distro packages often
  lag, so you may need a manual install from
  <https://ziglang.org/download/>. Check with `zig version`.
- **pkg-config** and **blueprint-compiler** (0.16.0 or newer).
- **GTK4 and libadwaita** dev files plus their dependencies: glib2,
  harfbuzz, freetype2, fontconfig, oniguruma, bzip2, libxml2, zlib.
- Windowing dev files for X11 (libX11, libXcursor, libXext, libXi,
  libXinerama, libXrandr) and/or Wayland (wayland, wayland-protocols).
- **gtk4-layer-shell** (optional, for the Wayland quick terminal).

On Fedora:

```sh
sudo dnf install zig pkgconf-pkg-config blueprint-compiler \
  gtk4-devel libadwaita-devel gtk4-layer-shell-devel \
  glib2-devel harfbuzz-devel freetype-devel fontconfig-devel \
  oniguruma-devel bzip2-devel libxml2-devel zlib-devel \
  libX11-devel libXcursor-devel libXext-devel libXi-devel \
  libXinerama-devel libXrandr-devel wayland-devel wayland-protocols-devel
```

On Debian/Ubuntu use the same list with `-dev` instead of `-devel`
(for example `libgtk-4-dev`, `libadwaita-1-dev`, `libglib2.0-dev`).

Nothing else is needed to build or run the terminal. Two optional
features shell out to tools at runtime and quietly do less without them:

- *Set as Desktop App Icon* needs `python3` with Pillow
  (`python3-pillow`) to resize the image, or ImageMagick `convert` as a
  fallback. With neither installed the menu option does nothing.
- The branch pill uses `gh` (GitHub) or `glab` (GitLab) to find an open
  PR/MR. Without them it opens the branch page instead.
- The git status pill needs a difftool configured in git, for example
  `git config --global diff.guitool meld` (or `diff.tool`). Without one
  it shows a toast and does nothing.

### Get the source

```sh
git clone <your fork URL> ghostty
cd ghostty
git checkout feature/split-header
```

### Build and run without installing

```sh
./build-and-run.sh            # optimised (ReleaseFast) build, then runs it
./build-and-run.sh --debug    # faster to compile, slower to run
./build-and-run.sh -- -e htop # pass arguments through to ghostty
```

This pins the version string to `1.3.2-sutts` so that committing does not
force a full recompile, and launches `zig-out/bin/ghostty` with
`--gtk-single-instance=false` so the window is not handed to an
already-running stock Ghostty that knows nothing about split headers.

### Install

```sh
./build-and-run.sh --install            # installs into ~/.local
PREFIX=/opt/ghostty ./build-and-run.sh --install
```

The install:

1. Runs `zig build -p $PREFIX -Doptimize=ReleaseFast`, which places the
   binary, desktop file, D-Bus service and systemd user unit under the
   prefix so launchers point at the installed binary.
2. Re-applies your custom app icon if `~/.config/ghostty/app-icon.png`
   exists.
3. Reloads the systemd user daemon and warns if the `ghostty` found on
   your `PATH` is not the one just installed (make sure `~/.local/bin`
   comes first).

Quit every running Ghostty window afterwards so new windows use the new
build.

To go back to a stock Ghostty later, remove the `split-header-*` lines
from your config first: official builds reject options they don't
recognise.

---

## Avatars: the coolicons collection

The avatar picker lists images from one directory. The
[coolicons](https://gitlab.com/countculture1/tools/coolicons) repository
("Agent Avatar Studio") holds 46 halftone-style portraits across eight
collections (big cats and dogs, NZ native birds, AI agents, sports stars,
mascots, technical specialists, core agent roles, icons and legends), plus
an `index.html` gallery you can open in a browser to browse and search
them.

Check it out next to your other projects:

```sh
git clone https://gitlab.com/countculture1/tools/coolicons.git ~/projects/coolicons
```

The pictures the picker should use are in `images/` (JPEG and PNG; the
`originals/` folder holds the full-size sources and is not needed by
Ghostty). Point the header at that folder in your config:

```ini
split-header-avatar-dir = /home/sutts/projects/coolicons/images
split-header-default-avatar = sutts_avatar.jpg
```

Then, in a running terminal:

1. Click the avatar in any split header to open the picker. Every image
   in `images/` appears in an eight-column grid.
2. Left-click an image to use it for that split. The header tint and
   surface outline pick up the image's dominant colour.
3. Right-click an image for *Set as Default Split Avatar* (writes the
   file name into your config so new splits use it) or *Set as Desktop App
   Icon* (turns it into Ghostty's launcher and taskbar icon; needs
   `python3-pillow`).

To add your own images, drop PNG, JPEG or WebP files into `images/` (or any
other directory you point `split-header-avatar-dir` at). Square images
around 512×512 work best; the app-icon option resizes down to 16×16, so
keep the subject large and centred.

If you would rather not depend on the checkout, copy the files you want
into the default location, `~/.config/ghostty/avatars`, and leave
`split-header-avatar-dir` unset.

---

## Configuration

Ghostty reads its configuration from
`$XDG_CONFIG_HOME/ghostty/config`, which is normally:

```
~/.config/ghostty/config
```

If that file does not exist, create it. One `key = value` per line; lines
starting with `#` are comments. Restart Ghostty, or use the *Reload
Configuration* action, after editing. The *Set as Default Split Avatar*
helper edits this same file (or `config.ghostty` if you use that name
instead).

All of the options below go in that file. The first two are stock Ghostty
options; the `split-header-*` ones exist only in this build, and
`window-save-state` is a stock option that this build makes work on Linux.

```ini
# Sutts
gtk-wide-tabs = false
font-size = 10
split-header = true
split-header-style = banner
split-header-size = 2
split-header-avatar-dir = /home/sutts/projects/coolicons/images
split-header-default-avatar = sutts_avatar.jpg
split-header-diff-command = smerge .
shell-integration-features = ssh-env
window-save-state = always
```

### `gtk-wide-tabs = false`

Stock Ghostty option, Linux only. By default GTK tabs are "wide" in the
current GNOME style, stretching to fill the whole tab bar. Setting this
to `false` makes each tab only as wide as its title needs, the older
compact look, so more tabs fit before the bar starts scrolling.

### `font-size = 10`

Stock option. The terminal font size in points. On GTK the value is
further scaled by your desktop's display scale and large-text settings.
Changing it at runtime affects only terminals whose font size you have not
already adjusted with the zoom keybindings. Ghostty's default on Linux
is 12.

### `split-header = true`

Fork option. Turns the header strip above each split on or off. This
build defaults it to `true`, so the line is optional but makes the
intent explicit. Set to `false` for a plain upstream-style layout. The
working directory and git information in the header need shell
integration, which Ghostty injects automatically for bash, zsh, fish,
elvish and nushell.

### `split-header-style = banner`

Fork option. The starting layout for every header. Individual splits can
still change theirs with the style button or the context-menu submenu.

- `portrait` (default) – a rounded avatar beside the title, with the
  working directory on the left and git details on the right beneath it.
- `banner` – a larger avatar flush to the edge that fades into the header
  background, with the details shown as pills. This is the style in the
  config above.
- `rail` – a compact round avatar and the title, with the details in a
  full-width strip underneath.

### `split-header-size = 2`

Fork option. The starting header size, in the same steps as the − and +
buttons on the header. The range is `-2` (smallest) to `3` (largest),
with `0` as the standard size; values outside the range are clamped. `2`
is two steps larger than standard, which suits the banner style's bigger
avatar. Each split can still be adjusted independently afterwards.

### `split-header-avatar-dir = /home/sutts/projects/coolicons/images`

Fork option. The directory the avatar picker lists. Only `.png`, `.jpg`,
`.jpeg` and `.webp` files are shown. When unset it defaults to
`~/.config/ghostty/avatars`. A leading `~/` is expanded to your home
directory; anything else is taken as-is.
Here it points at the `images/` folder of the coolicons checkout
described above.

### `split-header-default-avatar = sutts_avatar.jpg`

Fork option. The file name, inside `split-header-avatar-dir`, of the
avatar shown in every header that has not had one picked. If the file is
missing the header shows a placeholder icon and logs a warning. The
picker's *Set as Default Split Avatar* option writes or replaces this
line for you.

### `split-header-diff-command = smerge .`

Fork option. What clicking the git status counts in a header runs. The
command is run with `/bin/sh -c` in the split's working directory, with
`BASE` in its environment set to the base branch (`main`, else `master`,
else `origin/HEAD`; empty if none). When unset, the click runs
`git difftool --dir-diff --no-prompt --tool=<tool> $BASE` using the git
`diff.guitool` setting, falling back to `diff.tool`, which suits tools
that can diff directories such as GoLand (`goland diff`) or VS Code
(`code --diff`). Sublime Merge has no directory diff, so `smerge .`
opens the repository in it instead; something like
`goland diff "$PWD" "$(git rev-parse --show-toplevel)"` or
`git difftool --dir-diff --tool=vscode "$BASE"` are also valid values.

### `shell-integration-features = ssh-env`

Stock option. A comma-separated list of shell-integration features to
enable; features you leave out keep their defaults, so this line adds
`ssh-env` on top of the usual `cursor`, `sudo` and `title`.

`ssh-env` wraps `ssh` so that the remote side sees `TERM=xterm-256color`
instead of `xterm-ghostty`, and forwards `COLORTERM`, `TERM_PROGRAM` and
`TERM_PROGRAM_VERSION`. Every host already has the `xterm-256color`
terminfo entry, so nano, less, htop and friends work immediately, and
because `COLORTERM=truecolor` is forwarded, modern programs still use
24-bit colour. It also gives the split header's hostname and SSH badge a
reliable signal for remote sessions.

#### Why not `ssh-terminfo`

Ghostty also offers `ssh-terminfo`, which installs Ghostty's own
`xterm-ghostty` entry on the remote host with `tic` on first connection
and then keeps `TERM=xterm-ghostty` there. It sounds better, but the
install goes into the login user's `~/.terminfo`, and on Ubuntu (and most
distros) `sudo` resets `HOME` to `/root`, so anything run under sudo
cannot find it:

```
$ sudo nano /etc/pulsar/pulsar.env
ncurses: cannot initialize terminal type ($TERM="xterm-ghostty"); exiting
```

The fix is a one-off system-wide install on every host
(`infocmp -x xterm-ghostty | sudo tic -x -o /usr/share/terminfo -`),
which is easy to forget on a new server and fails silently until the
next `sudo nano`. `ssh-env` alone avoids the problem entirely.

What you give up by not shipping the full entry is small:

- Curly and coloured underlines in older vim and helix on the remote
  (neovim 0.10+ asks the terminal directly and keeps them).
- Synchronized output for a remote `tmux`, so heavy redraws may tear
  slightly. Neovim negotiates this itself and is unaffected.
- Overline, and 24-bit colour advertised through terminfo for old
  ncurses-only programs that ignore `COLORTERM`.

If you do want the full entry on a host you administer, run the
`infocmp | sudo tic` line above once as your login user; `ssh-env` will
still send `xterm-256color`, so also `export TERM=xterm-ghostty` in that
host's shell profile.

### `window-save-state = always`

Stock option that upstream only honours on macOS; this build implements
it on Linux (see *Session save and restore* above). `always` saves the
window, tab and split layout plus working directories to
`~/.local/state/ghostty/session.json` on a clean quit and restores it at
the next launch. `never` disables it, and `default` behaves like `never`
on Linux. Named profiles from the context menu work regardless of this
setting.
