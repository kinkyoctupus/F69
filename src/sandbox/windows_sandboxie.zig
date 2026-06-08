// Sandboxie-Plus integration. The user installs Sandboxie themselves; we DETECT their install
// and shell out to `Start.exe /box:<box> <command>`. If it isn't found, the Sandbox falls back
// to the `none` backend (game runs unsandboxed).
//
// Detection priority:
//   1. config `sandboxie_path` — the user can Browse… to Start.exe in Settings (Appearance/Sandbox)
//   2. %ProgramFiles%\Sandboxie-Plus\Start.exe   (Sandboxie-Plus)
//   3. %ProgramFiles%\Sandboxie\Start.exe        (classic Sandboxie)

const std = @import("std");
const builtin = @import("builtin");
const errs = @import("errors.zig");
const dom = @import("domain.zig");

const log = std.log.scoped(.sandbox);

pub const Sandboxie = struct {
    start_exe: []const u8, // resolved Start.exe path (owned by `alloc`)
    alloc: std.mem.Allocator,
    io: std.Io,

    /// Detect Sandboxie. `override` = `config.sandboxie_path` (empty when unset). Returns null
    /// when Sandboxie isn't found so `pickBackend` falls back to `none`.
    pub fn detect(alloc: std.mem.Allocator, io: std.Io, environ: std.process.Environ, override: []const u8) ?Sandboxie {
        if (builtin.os.tag != .windows) return null;
        // 1. explicit config override (the "Browse to Start.exe" target).
        if (fromExplicitPath(alloc, io, override)) |s| {
            log.info("sandboxie: using configured Start.exe at {s}", .{s.start_exe});
            return s;
        }
        // 2/3. standard install locations under %ProgramFiles%.
        const pf = environ.getAlloc(alloc, "ProgramFiles") catch return null;
        defer alloc.free(pf);
        const subdirs = [_][]const u8{ "Sandboxie-Plus", "Sandboxie" };
        for (subdirs) |sub| {
            const p = std.fmt.allocPrint(alloc, "{s}\\{s}\\Start.exe", .{ pf, sub }) catch continue;
            if (exists(io, p)) {
                log.info("sandboxie: detected Start.exe at {s}", .{p});
                return .{ .start_exe = p, .alloc = alloc, .io = io };
            }
            alloc.free(p);
        }
        return null;
    }

    /// Build a Sandboxie from an explicit Start.exe path — the Settings
    /// "Browse…" target / config override, used for portable or otherwise
    /// non-standard installs. Returns null when the path is empty or doesn't
    /// exist on disk (so the caller keeps the current backend). Caller owns
    /// the resulting `start_exe`.
    pub fn fromExplicitPath(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Sandboxie {
        if (builtin.os.tag != .windows) return null;
        if (path.len == 0 or !exists(io, path)) return null;
        const dup = alloc.dupe(u8, path) catch return null;
        return .{ .start_exe = dup, .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Sandboxie) void {
        if (self.start_exe.len > 0) self.alloc.free(self.start_exe);
    }

    /// Launch the game inside a Sandboxie box: `Start.exe /box:f69 <abs_exe> [args]`.
    pub fn launch(self: *Sandboxie, alloc: std.mem.Allocator, cfg: dom.SandboxConfig) errs.Error!dom.SpawnResult {
        var exe_buf: [1024]u8 = undefined;
        const abs_exe: []const u8 = if (std.fs.path.isAbsolute(cfg.executable))
            cfg.executable
        else
            std.fmt.bufPrint(&exe_buf, "{s}\\{s}", .{ cfg.install_path, cfg.executable }) catch return errs.Error.LaunchFailed;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, self.start_exe) catch return errs.Error.OutOfMemory;
        argv.append(alloc, "/box:f69") catch return errs.Error.OutOfMemory;
        argv.append(alloc, abs_exe) catch return errs.Error.OutOfMemory;
        for (cfg.launch_args) |a| argv.append(alloc, a) catch return errs.Error.OutOfMemory;

        _ = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cfg.install_path },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |e| {
            log.warn("sandboxie launch failed: {s} (start={s}, exe={s})", .{ @errorName(e), self.start_exe, abs_exe });
            return errs.Error.LaunchFailed;
        };
        // Game runs detached inside the box. Host-side pid tracking on Windows is M2 → report 0.
        return .{ .pid = 0 };
    }
};

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
