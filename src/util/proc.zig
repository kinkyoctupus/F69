// Child-process spawn helper. Consolidates the ad-hoc `std.process.spawn`
// usage scattered across 14 sites (aria2 daemon spawn, bwrap launch,
// ldd probe, tar/zip shellouts, libarchive helpers). Each site rolled
// its own argv setup + stdout capture + status handling; this helper
// is one place to add timeout, cancellation, env scrubbing, etc. as
// they become needed.
//
// What this does NOT do:
//   - Persistent / long-lived children (aria2 daemon, bwrap launch).
//     Those want explicit `std.process.Child` lifecycle in their own
//     module — passing a child handle through this helper doesn't fit.
//     Use this helper for one-shot "run X and read stdout" calls.

const std = @import("std");

pub const Error = error{
    SpawnFailed,
    ExitCode,
    OutOfMemory,
    StdoutCaptureFailed,
};

pub const RunResult = struct {
    /// Captured stdout. Allocator-owned (caller frees).
    stdout: []u8,
    /// Process exit code. 0 = clean exit; non-zero is whatever the
    /// child decided.
    exit_code: u8,
};

/// Selector for the child's stderr stream. Most one-shot callers want
/// `.inherit` so a failing helper (chmod, ldd, tar) writes the error
/// message into the parent's console without extra plumbing. Best-effort
/// probes (`testUserns`, silent `chmod +x`) want `.ignore` so the noise
/// stays out of the user's log.
pub const StderrBehavior = enum { inherit, ignore };

pub const RunOptions = struct {
    /// Working directory. Null inherits the parent's cwd.
    cwd: ?[]const u8 = null,
    /// Max captured-stdout bytes. Children writing more than this
    /// surface `StdoutCaptureFailed`. Default 4 MiB.
    max_stdout_bytes: usize = 4 * 1024 * 1024,
    /// What to do with the child's stderr. Defaults to `.inherit` so
    /// failure messages reach the parent console without ceremony.
    stderr: StderrBehavior = .inherit,
};

/// Spawn `argv`, wait for exit, return captured stdout + exit code.
/// stderr handling follows `opts.stderr` (defaults to inherit so
/// failure messages are visible without extra plumbing).
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    opts: RunOptions,
) Error!RunResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = switch (opts.stderr) {
            .inherit => .inherit,
            .ignore => .ignore,
        },
        .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
    }) catch return Error.SpawnFailed;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();

    var fr_buf: [4096]u8 = undefined;
    var fr = child.stdout.?.reader(io, &fr_buf);
    _ = fr.interface.streamRemaining(&aw.writer) catch {
        child.kill(io);
        aw.deinit();
        return Error.StdoutCaptureFailed;
    };

    if (aw.writer.buffered().len > opts.max_stdout_bytes) {
        child.kill(io);
        aw.deinit();
        return Error.StdoutCaptureFailed;
    }

    const term = child.wait(io) catch {
        aw.deinit();
        return Error.SpawnFailed;
    };

    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1, // signal / unknown — surface as non-zero
    };

    const stdout = aw.toOwnedSlice() catch return Error.OutOfMemory;
    return .{ .stdout = stdout, .exit_code = code };
}
