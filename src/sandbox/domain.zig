// Sandbox configuration types. SandboxConfig is per-launch; it's built
// from the recipe's `sandbox` block + per-game override + AppConfig
// default.

const std = @import("std");

/// Canonical Distro lives in `util_domain`.
pub const Distro = @import("util_domain").Distro;

/// Host-side environment data the bwrap backend needs to wire up the
/// sandbox's display + audio sockets. Caller fills from
/// `init.minimal.environ` at launch time.
pub const HostInfo = struct {
    /// `$XDG_RUNTIME_DIR` — parent of wayland/pipewire/pulse/dbus sockets.
    xdg_runtime_dir: ?[]const u8 = null,
    /// `$WAYLAND_DISPLAY` — typically "wayland-1".
    wayland_display: ?[]const u8 = null,
    /// `$DISPLAY` — X11 display, e.g. ":0".
    x11_display: ?[]const u8 = null,
    /// `$HOME` — used as the source for fontconfig user font path.
    home: ?[]const u8 = null,
};

pub const EnvOverride = struct {
    name: []const u8,
    /// Final value to set. Prepend/append composition (e.g. compat
    /// recipes wanting `LD_LIBRARY_PATH=<resource>:<existing>`) is
    /// done by the caller — the sandbox just sets whatever it's given.
    value: []const u8,
};

pub const SandboxConfig = struct {
    /// Allow network. Recipe-level default; `false` adds `--unshare-net`.
    network: bool = true,
    /// Extra read-only host paths to bind into the sandbox (useful for
    /// system fonts, GPU drivers when default binds aren't enough).
    bind_extra: []const []const u8 = &.{},
    /// Per-game sandbox HOME, shared across versions. Path on the host;
    /// the sandbox sees this as $HOME. Must exist + be writable.
    sandbox_home: []const u8,
    /// Read-only bind for the install dir. Bound at /game inside the
    /// sandbox + chdir'd into.
    install_path: []const u8,
    /// Game executable, relative to install_path. Either `./foo.sh`
    /// or `foo.sh` — both resolved against /game.
    executable: []const u8,
    launch_args: []const []const u8 = &.{},
    /// Host environment snapshot — filled from `std.process.Init.environ`.
    host: HostInfo = .{},
    /// Extra env vars to inject at launch time. Compat recipes emit
    /// these to provide host-compat libraries (LD_LIBRARY_PATH, etc).
    /// Applied after HOME is set so a recipe that overrides HOME via
    /// env_extra wins. Empty = no overrides.
    env_extra: []const EnvOverride = &.{},
};

pub const SpawnResult = struct {
    /// PID of the launched process (host-side).
    pid: i32,
};
