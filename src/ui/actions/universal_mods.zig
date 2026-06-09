//! Universal (engine-wide) mods — management actions (feature C). Add copies
//! a picked modfile into `<data_root>/universal-mods/` and registers it for an
//! engine; delete removes the row + the copied file. The apply pipeline
//! (install each engine mod into eligible games) reuses the per-game mod
//! machinery and is wired separately.

const std = @import("std");
const Io = std.Io;
const library = @import("library");
const installer = @import("installer");
const file_picker = @import("util_file_picker");
const types = @import("../types.zig");

const Frame = types.Frame;
const log = std.log.scoped(.umods);

/// Engines offered in the add-form dropdown (index ↔ enum). Kept small —
/// the engines that actually have moddable assets.
pub const ENGINES = [_]library.Engine{ .renpy, .rpgm_mv, .rpgm_mz, .unity, .unreal, .html, .other };

pub fn engineForIndex(idx: usize) library.Engine {
    return if (idx < ENGINES.len) ENGINES[idx] else .other;
}

pub fn doAddUniversalMod(frame: *Frame, engine: library.Engine) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const picked = file_picker.open(alloc, &[_]file_picker.FilterItem{
        .{ .name = "Mod archives", .spec = "zip,7z,rar,tar,gz,bz2,xz" },
        .{ .name = "All files", .spec = "" },
    }, null) catch |e| {
        var buf: [160]u8 = undefined;
        frame.state.notifyErr(std.fmt.bufPrint(&buf, "Pick failed: {s}", .{@errorName(e)}) catch "Pick failed");
        return;
    };
    const src = picked orelse return;
    defer alloc.free(src);

    const base = std.fs.path.basename(src);

    // Copy into <data_root>/universal-mods/<basename>.
    var dir_buf: [1024]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dir_buf, "{s}/universal-mods", .{frame.info.data_root}) catch {
        frame.state.notifyErr("Add: path too long.");
        return;
    };
    Io.Dir.cwd().createDirPath(io, dest_dir) catch {
        frame.state.notifyErr("Add: couldn't create universal-mods dir.");
        return;
    };
    var dest_buf: [1024]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dest_dir, base }) catch {
        frame.state.notifyErr("Add: path too long.");
        return;
    };
    copyFile(io, alloc, src, dest) catch |e| {
        log.warn("copy {s} → {s} failed: {s}", .{ src, dest, @errorName(e) });
        frame.state.notifyErr("Add: couldn't copy the modfile.");
        return;
    };

    // Name = the form field if set, else the filename.
    const name_end = std.mem.indexOfScalar(u8, &frame.state.universal_mod_name_buf, 0) orelse frame.state.universal_mod_name_buf.len;
    const typed = std.mem.trim(u8, frame.state.universal_mod_name_buf[0..name_end], " \t\r\n");
    const name = if (typed.len > 0) typed else base;

    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    _ = frame.lib.createUniversalMod(name, engine, dest, now) catch {
        frame.state.notifyErr("Add: database write failed.");
        return;
    };
    @memset(&frame.state.universal_mod_name_buf, 0);
    frame.state.notifyOk("Universal mod added.");
}

pub fn doDeleteUniversalMod(frame: *Frame, id: i64, modfile_path: []const u8) void {
    frame.lib.deleteUniversalMod(id) catch {
        frame.state.notifyErr("Delete failed.");
        return;
    };
    // Best-effort: drop the copied modfile (ignore if it's outside our dir).
    if (std.mem.indexOf(u8, modfile_path, "/universal-mods/") != null) {
        Io.Dir.cwd().deleteFile(frame.io, modfile_path) catch {};
    }
    frame.state.notifyOk("Universal mod removed.");
}

/// Distribute a universal mod to every eligible game (engine match, not
/// opted out): registers its modfile as a managed modfile on each game (with
/// auto-preset detection), so it shows up + applies through the normal
/// per-game mod flow. Idempotent — re-running just no-ops on duplicates.
pub fn applyUniversalMod(frame: *Frame, mod_id: i64, engine: library.Engine, modfile_path: []const u8) void {
    const alloc = frame.lib.alloc;
    const ma = installer.mod_archives;
    var applied: usize = 0;
    for (frame.games) |*g| {
        if (g.engine != engine) continue;
        if (frame.lib.isUniversalModDisabled(g.f95_thread_id, mod_id) catch false) continue;
        const res = ma.addForGame(alloc, frame.io, frame.info.mod_archives_dir, g.f95_thread_id, modfile_path) catch continue;
        switch (res) {
            .added => |m| {
                ma.freeModfile(alloc, m);
                applied += 1;
            },
            .duplicate => |d| {
                ma.freeModfile(alloc, d.existing);
                applied += 1;
            },
        }
    }
    var buf: [96]u8 = undefined;
    frame.state.notifyOk(std.fmt.bufPrint(&buf, "Universal mod available on {d} game(s).", .{applied}) catch "Applied.");
}

fn copyFile(io: Io, alloc: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, src, alloc, .limited(2 * 1024 * 1024 * 1024));
    defer alloc.free(bytes);
    var f = try Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer f.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}
