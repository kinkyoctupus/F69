// spike-01: bwrap a process with per-display-server bindings.
// Throwaway PoC. Goal: validate the bwrap arg list across NixOS / Debian /
// Arch / Fedora before sinking time into the real `sandbox/` module.
//
// Built against Zig 0.16's new std.Io / std.process.Init main signature.
//
// Usage:
//   zig build spike-bwrap -- <install_path> <sandbox_home> [-- <argv...>]
//
// Default child if argv omitted: a small bash diagnostic.

const std = @import("std");
const Io = std.Io;

const Distro = enum { nixos, arch, debian, ubuntu, fedora, other };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        try Io.File.stdout().writeStreamingAll(io,
            \\spike-01-bwrap — sandbox launcher PoC
            \\
            \\usage: spike-bwrap <install_path> <sandbox_home> [-- <argv...>]
            \\
            \\<install_path>   game directory (read-only inside sandbox at /game)
            \\<sandbox_home>   per-game host dir; sandbox sees as $HOME (rw)
            \\<argv...>        optional child command (default: bash diag)
            \\
        );
        return;
    }

    const install_path = args[1];
    const sandbox_home = args[2];

    var child_argv: []const [:0]const u8 = &.{};
    for (args, 0..) |a, i| {
        if (i >= 3 and std.mem.eql(u8, a, "--")) {
            child_argv = args[i + 1 ..];
            break;
        }
    }

    // 1. Distro
    const distro = try detectDistro(io, gpa);
    try printf(io, "[spike] distro: {s}\n", .{@tagName(distro)});

    // 2. bwrap on PATH
    const bwrap_path = findInPath(arena, io, init.minimal.environ, "bwrap") catch {
        try printf(io, "[spike] bwrap: NOT FOUND on PATH\n", .{});
        try printf(io,
            "[spike] hint: nix-shell -p bubblewrap | apt install bubblewrap | pacman -S bubblewrap | dnf install bubblewrap\n",
            .{},
        );
        return;
    };
    try printf(io, "[spike] bwrap: {s}\n", .{bwrap_path});

    // 3. Unprivileged userns smoke test
    const userns_ok = testUserns(io);
    try printf(io, "[spike] unpriv userns: {s}\n", .{if (userns_ok) "OK" else "BLOCKED"});
    if (!userns_ok) {
        try printf(io,
            \\[spike] hint:
            \\  - NixOS: check `boot.kernel.sysctl.kernel.unprivileged_userns_clone` (rare).
            \\  - Debian 12: `sudo sysctl kernel.unprivileged_userns_clone=1` (persist in /etc/sysctl.d/).
            \\  - Ubuntu 24.04: AppArmor profile blocks; install `apparmor-profiles-extra` or use unconfined.
            \\
        , .{});
        return;
    }

    // 4. Display server detection
    const xdg_runtime = init.minimal.environ.getAlloc(arena, "XDG_RUNTIME_DIR") catch null;
    const wayland = init.minimal.environ.getAlloc(arena, "WAYLAND_DISPLAY") catch null;
    const x11 = init.minimal.environ.getAlloc(arena, "DISPLAY") catch null;

    try printf(io, "[spike] display: wayland={?s} x11={?s} runtime={?s}\n", .{ wayland, x11, xdg_runtime });

    // 5. Build bwrap arg list
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, bwrap_path);

    // OS isolation
    try argv.appendSlice(arena, &.{
        "--unshare-user",       "--unshare-pid",       "--unshare-ipc",
        "--unshare-uts",        "--unshare-cgroup-try",
        "--die-with-parent",
    });

    // Read-only filesystem skeleton
    try argv.appendSlice(arena, &.{
        "--ro-bind", "/usr", "/usr",
        "--ro-bind-try", "/etc/resolv.conf", "/etc/resolv.conf",
        "--ro-bind-try", "/etc/hostname", "/etc/hostname",
        "--ro-bind-try", "/etc/hosts", "/etc/hosts",
        "--ro-bind-try", "/etc/localtime", "/etc/localtime",
        "--ro-bind-try", "/etc/passwd", "/etc/passwd",
        "--ro-bind-try", "/etc/group", "/etc/group",
        "--ro-bind-try", "/etc/machine-id", "/etc/machine-id",
        "--ro-bind-try", "/etc/ssl", "/etc/ssl",
        "--ro-bind-try", "/etc/ca-certificates", "/etc/ca-certificates",
    });

    if (distro == .nixos) {
        // NixOS userland lives in /nix/store + /run/current-system.
        try argv.appendSlice(arena, &.{
            "--ro-bind-try", "/nix",                  "/nix",
            "--ro-bind-try", "/run/current-system",   "/run/current-system",
            "--ro-bind-try", "/run/wrappers",         "/run/wrappers",
            "--ro-bind-try", "/run/opengl-driver",    "/run/opengl-driver",
            "--ro-bind-try", "/run/opengl-driver-32", "/run/opengl-driver-32",
        });
    } else {
        try argv.appendSlice(arena, &.{
            "--ro-bind-try", "/lib",   "/lib",
            "--ro-bind-try", "/lib32", "/lib32",
            "--ro-bind-try", "/lib64", "/lib64",
            "--ro-bind-try", "/bin",   "/bin",
            "--ro-bind-try", "/sbin",  "/sbin",
        });
    }

    // /tmp + /run scratch + /proc + /dev
    try argv.appendSlice(arena, &.{
        "--tmpfs", "/tmp",
        "--tmpfs", "/run",
        "--proc",  "/proc",
        "--dev",   "/dev",
        "--dev-bind-try", "/dev/dri", "/dev/dri",
        "--dev-bind-try", "/dev/nvidia0", "/dev/nvidia0",
        "--dev-bind-try", "/dev/nvidiactl", "/dev/nvidiactl",
        "--dev-bind-try", "/dev/nvidia-modeset", "/dev/nvidia-modeset",
        "--dev-bind-try", "/dev/nvidia-uvm", "/dev/nvidia-uvm",
        "--dev-bind-try", "/dev/shm", "/dev/shm",
    });

    // Sandbox HOME (rw) + game install (ro)
    try argv.appendSlice(arena, &.{
        "--bind",    sandbox_home, sandbox_home,
        "--ro-bind", install_path, "/game",
    });

    // Display server sockets
    if (xdg_runtime) |runtime| {
        const pipewire = try std.fmt.allocPrint(arena, "{s}/pipewire-0", .{runtime});
        try argv.appendSlice(arena, &.{ "--ro-bind-try", pipewire, pipewire });

        const pulse = try std.fmt.allocPrint(arena, "{s}/pulse", .{runtime});
        try argv.appendSlice(arena, &.{ "--ro-bind-try", pulse, pulse });

        const dbus = try std.fmt.allocPrint(arena, "{s}/bus", .{runtime});
        try argv.appendSlice(arena, &.{ "--ro-bind-try", dbus, dbus });

        if (wayland) |wd| {
            const wpath = try std.fmt.allocPrint(arena, "{s}/{s}", .{ runtime, wd });
            try argv.appendSlice(arena, &.{ "--ro-bind-try", wpath, wpath });
        }
    }

    if (x11 != null) {
        try argv.appendSlice(arena, &.{ "--ro-bind-try", "/tmp/.X11-unix", "/tmp/.X11-unix" });
    }

    // Env + cwd
    try argv.appendSlice(arena, &.{
        "--setenv", "HOME", sandbox_home,
        "--chdir",  "/game",
    });

    // Default child or user-provided
    if (child_argv.len > 0) {
        for (child_argv) |a| try argv.append(arena, a);
    } else {
        try argv.appendSlice(arena, &.{
            "bash", "-c",
            \\echo "[child] HOME=$HOME PWD=$PWD"
            \\echo "[child] /game contents:"; ls /game | head -5 || true
            \\echo -n "[child] writable HOME?: "; { touch "$HOME/.f69-spike-test" && rm -f "$HOME/.f69-spike-test"; } 2>/dev/null && echo "yes" || echo "NO"
            \\echo -n "[child] network?: "; getent hosts f95zone.to >/dev/null 2>&1 && echo "yes" || echo "no/blocked"
        });
    }

    // 6. Print argv for inspection
    try printf(io, "[spike] argv:\n", .{});
    for (argv.items) |a| try printf(io, "  {s}\n", .{a});

    // 7. Spawn it
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try printf(io, "[spike] child exited: {d}\n", .{code}),
        .signal => |sig| try printf(io, "[spike] child signaled: {s}\n", .{@tagName(sig)}),
        .stopped => |sig| try printf(io, "[spike] child stopped: {s}\n", .{@tagName(sig)}),
        .unknown => |c| try printf(io, "[spike] child terminated abnormally: {d}\n", .{c}),
    }
}

// ---------------- helpers ----------------

fn printf(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
    try Io.File.stdout().writeStreamingAll(io, out);
}

fn detectDistro(io: Io, gpa: std.mem.Allocator) !Distro {
    const content = Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", gpa, .unlimited) catch return .other;
    defer gpa.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "ID=")) {
            const v = std.mem.trim(u8, line[3..], "\"' \t");
            if (std.mem.eql(u8, v, "nixos")) return .nixos;
            if (std.mem.eql(u8, v, "arch")) return .arch;
            if (std.mem.eql(u8, v, "debian")) return .debian;
            if (std.mem.eql(u8, v, "ubuntu")) return .ubuntu;
            if (std.mem.eql(u8, v, "fedora")) return .fedora;
            return .other;
        }
    }
    return .other;
}

fn findInPath(arena: std.mem.Allocator, io: Io, environ: std.process.Environ, name: []const u8) ![]const u8 {
    const path_env = environ.getAlloc(arena, "PATH") catch return error.PathUnset;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return error.NotFound;
}

fn testUserns(io: Io) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "unshare", "-Ur", "--", "true" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
