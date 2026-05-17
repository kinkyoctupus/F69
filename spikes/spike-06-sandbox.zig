// spike-06: smoke-test the production sandbox/linux_bwrap.zig path.
//
// Layout (matches what the UI's Launch action does at runtime):
//
//   /tmp/f69-sandbox-spike/install/    ← read-only inside sandbox, bound at /game
//     play.sh                          ← dummy `echo hello`
//   /tmp/f69-sandbox-spike/install/.f69-home/   ← writable sandbox HOME
//
// Calls `sandbox.pickBackend(...)` (real detection) then `Sandbox.launch(...)`
// (real argv + spawn). Inherits the child's stdout so you see "hello inside
// sandbox" come out.
//
// Usage (inside `nix develop`):
//   zig build spike-sandbox
//   ./zig-out/bin/spike-sandbox

const std = @import("std");
const Io = std.Io;
const sandbox_mod = @import("sandbox");

const ROOT = "/tmp/f69-sandbox-spike";
const INSTALL_DIR = ROOT ++ "/install";
const SANDBOX_HOME = ROOT ++ "/install/.f69-home";
const SCRIPT_NAME = "play.sh";
const SCRIPT_BODY =
    \\#!/usr/bin/env bash
    \\echo "hello inside sandbox"
    \\echo "  HOME=$HOME"
    \\echo "  PWD=$PWD"
    \\echo "  contents of /game:"
    \\ls /game | sed 's/^/    /'
    \\echo -n "  writable HOME? "
    \\if touch "$HOME/.spike-test" 2>/dev/null; then
    \\  echo "yes"
    \\  rm -f "$HOME/.spike-test"
    \\else
    \\  echo "NO"
    \\fi
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try std.Io.Dir.cwd().createDirPath(io, INSTALL_DIR);
    try std.Io.Dir.cwd().createDirPath(io, SANDBOX_HOME);

    // Write the dummy script (truncating) and chmod +x afterwards
    // — Io.Dir.CreateFileOptions has no mode field in 0.16.
    const script_path = INSTALL_DIR ++ "/" ++ SCRIPT_NAME;
    {
        var f = try std.Io.Dir.cwd().createFile(io, script_path, .{ .truncate = true });
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(SCRIPT_BODY);
        try w.interface.flush();
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }

    // Real detection — bwrap on Linux, sandboxie on Windows, none otherwise.
    var sandbox = sandbox_mod.pickBackend(gpa, io, init.minimal.environ);
    defer sandbox.deinit();
    std.debug.print("[spike-06] backend: {s}\n", .{sandbox.backendName()});

    if (sandbox == .none) {
        std.debug.print("[spike-06] no sandbox backend available (no bwrap on PATH or userns blocked)\n", .{});
        std.debug.print("[spike-06] hint: nix-shell -p bubblewrap, or sudo sysctl kernel.unprivileged_userns_clone=1\n", .{});
        return;
    }

    // Snapshot the display + audio env so the sandbox knows where to
    // wire sockets. NULLs are fine — buildArgv skips missing pieces.
    const xdg_runtime = init.minimal.environ.getAlloc(gpa, "XDG_RUNTIME_DIR") catch null;
    defer if (xdg_runtime) |v| gpa.free(v);
    const wayland = init.minimal.environ.getAlloc(gpa, "WAYLAND_DISPLAY") catch null;
    defer if (wayland) |v| gpa.free(v);
    const x11 = init.minimal.environ.getAlloc(gpa, "DISPLAY") catch null;
    defer if (x11) |v| gpa.free(v);
    const home = init.minimal.environ.getAlloc(gpa, "HOME") catch null;
    defer if (home) |v| gpa.free(v);

    const cfg = sandbox_mod.SandboxConfig{
        .network = false, // headless test; no need for network in the sandbox
        .sandbox_home = SANDBOX_HOME,
        .install_path = INSTALL_DIR,
        .executable = "./" ++ SCRIPT_NAME,
        .host = .{
            .xdg_runtime_dir = xdg_runtime,
            .wayland_display = wayland,
            .x11_display = x11,
            .home = home,
        },
    };

    const result = try sandbox.launch(gpa, cfg);
    std.debug.print("[spike-06] launched pid={d}; waiting for child output above...\n", .{result.pid});

    // Crude wait: sleep 500ms so the child has time to print before we
    // exit. The real UI doesn't wait — it spawns + returns.
    io.sleep(Io.Duration.fromMilliseconds(500), .real) catch {};
    std.debug.print("[spike-06] done.\n", .{});
}
