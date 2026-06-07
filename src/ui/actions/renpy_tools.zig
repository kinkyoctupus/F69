//! Ren'Py "enable developer console" mod tool (M3 §2.1). Drops a tiny `.rpy`
//! into the game's `game/` directory that flips `config.console` +
//! `config.developer` on, so the user gets the in-engine console (Shift+O)
//! and dev menu (Shift+D) — the standard cheat/debug entry point for Ren'Py
//! games. Non-destructive: it only adds one file, removable by deleting it.

const std = @import("std");
const Io = std.Io;
const rpa = @import("util_rpa");
const types = @import("../types.zig");

const Frame = types.Frame;
const log = std.log.scoped(.renpy);

/// `init 999` runs after the game's own init blocks, so this overrides a
/// game that explicitly set `config.developer = False`.
const CONSOLE_RPY =
    "# Added by f69 — enables the Ren'Py developer console (Shift+O) + dev menu (Shift+D).\n" ++
    "# Delete this file to turn it back off.\n" ++
    "init 999 python:\n" ++
    "    config.console = True\n" ++
    "    config.developer = True\n";

const CONSOLE_FILENAME = "zzz_f69_console.rpy";

pub fn enableRenpyConsole(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse {
        frame.state.notifyErr("Console: no install found for this game.");
        return;
    };
    defer frame.lib.freeInstall(inst);

    const game_dir = findGameDir(alloc, io, inst.install_path) orelse {
        frame.state.notifyErr("Console: couldn't find the Ren'Py game/ folder.");
        return;
    };
    defer alloc.free(game_dir);

    var pbuf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ game_dir, CONSOLE_FILENAME }) catch {
        frame.state.notifyErr("Console: path too long.");
        return;
    };
    writeFile(io, path, CONSOLE_RPY) catch |e| {
        log.warn("write {s} failed: {s}", .{ path, @errorName(e) });
        frame.state.notifyErr("Console: couldn't write the .rpy file.");
        return;
    };
    frame.state.notifyOk("Ren'Py console enabled — press Shift+O in-game.");
}

/// Extract every `.rpa` archive found in the game's install into its own
/// directory (loose files next to the archive — Ren'Py prefers loose files,
/// so this makes assets/scripts moddable). Non-destructive: the `.rpa` is
/// kept. Reports total files extracted across archives.
pub fn extractRpaArchives(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse {
        frame.state.notifyErr("Extract: no install found for this game.");
        return;
    };
    defer frame.lib.freeInstall(inst);

    var dir = Io.Dir.cwd().openDir(io, inst.install_path, .{ .access_sub_paths = true, .iterate = true }) catch {
        frame.state.notifyErr("Extract: couldn't open the install directory.");
        return;
    };
    defer dir.close(io);
    var walker = dir.walk(alloc) catch {
        frame.state.notifyErr("Extract: out of memory.");
        return;
    };
    defer walker.deinit();

    var archives: usize = 0;
    var files: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.path, ".rpa")) continue;
        var path_buf: [1024]u8 = undefined;
        const rpa_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ inst.install_path, entry.path }) catch continue;
        var out_buf: [1024]u8 = undefined;
        const out_dir = std.fmt.bufPrint(&out_buf, "{s}/{s}", .{ inst.install_path, std.fs.path.dirname(entry.path) orelse "" }) catch continue;

        const n = extractOneRpa(alloc, io, rpa_path, out_dir) catch |e| {
            log.warn("extract {s} failed: {s}", .{ entry.path, @errorName(e) });
            continue;
        };
        archives += 1;
        files += n;
    }

    if (archives == 0) {
        frame.state.notifyWarn("No .rpa archives found in this install.");
        return;
    }
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Extracted {d} file(s) from {d} .rpa archive(s).", .{ files, archives }) catch "Extract complete.";
    frame.state.notifyOk(msg);
}

fn extractOneRpa(alloc: std.mem.Allocator, io: Io, rpa_path: []const u8, out_dir: []const u8) !usize {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, rpa_path, alloc, .limited(2 * 1024 * 1024 * 1024));
    defer alloc.free(bytes);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const entries = try rpa.loadIndex(arena.allocator(), bytes);

    var n: usize = 0;
    for (entries) |e| {
        if (!safeRelPath(e.name)) continue;
        const data_len = if (e.length >= e.prefix.len) e.length - e.prefix.len else 0;
        const start = e.offset;
        const end = start + data_len;
        if (end > bytes.len) continue; // corrupt / out-of-range entry

        var dst_buf: [1024]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ out_dir, e.name }) catch continue;
        if (std.fs.path.dirname(dst)) |d| Io.Dir.cwd().createDirPath(io, d) catch continue;

        var f = Io.Dir.cwd().createFile(io, dst, .{ .truncate = true }) catch continue;
        defer f.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(e.prefix) catch continue;
        fw.interface.writeAll(bytes[start..end]) catch continue;
        fw.interface.flush() catch continue;
        n += 1;
    }
    return n;
}

/// Reject absolute paths and any ".." segment — RPA names are untrusted.
fn safeRelPath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return false;
    return std.mem.indexOf(u8, name, "..") == null;
}

fn findGameDir(alloc: std.mem.Allocator, io: Io, root: []const u8) ?[]u8 {
    if (joinIfDir(alloc, io, root, "game")) |p| return p;
    // Some bundles wrap the game one level deeper — walk for a `game` dir.
    var dir = Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(alloc) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "game")) continue;
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, entry.path }) catch null;
    }
    return null;
}

/// Return an owned "<root>/<rel>" if it's an openable directory, else null.
fn joinIfDir(alloc: std.mem.Allocator, io: Io, root: []const u8, rel: []const u8) ?[]u8 {
    const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel }) catch return null;
    var d = Io.Dir.cwd().openDir(io, p, .{}) catch {
        alloc.free(p);
        return null;
    };
    d.close(io);
    return p;
}

fn writeFile(io: Io, path: []const u8, content: []const u8) !void {
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}
