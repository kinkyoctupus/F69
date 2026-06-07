//! RPG Maker MV/MZ "decrypt assets" mod tool (M3 §2.1). Walks a game's
//! latest install, reads the per-game `encryptionKey` from System.json, and
//! writes decrypted copies (.png/.ogg/.m4a) next to the encrypted originals.
//!
//! Non-destructive: originals are kept, so the game keeps running while the
//! user gets raw assets for modding/extraction. The pure cipher + filename
//! logic lives in util/rpgm_crypt.zig.

const std = @import("std");
const Io = std.Io;
const rpgm = @import("util_rpgm_crypt");
const types = @import("../types.zig");

const Frame = types.Frame;
const log = std.log.scoped(.rpgm);

pub fn decryptRpgmAssets(frame: *Frame, thread_id: u64) void {
    const alloc = frame.lib.alloc;
    const io = frame.io;

    const inst = (frame.lib.latestInstallForGame(thread_id) catch null) orelse {
        frame.state.notifyErr("Decrypt: no install found for this game.");
        return;
    };
    defer frame.lib.freeInstall(inst);
    const root = inst.install_path;

    const key = findKey(alloc, io, root) orelse {
        frame.state.notifyErr("Decrypt: couldn't find System.json encryptionKey.");
        return;
    };

    var dir = Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true }) catch {
        frame.state.notifyErr("Decrypt: couldn't open the install directory.");
        return;
    };
    defer dir.close(io);

    var walker = dir.walk(alloc) catch {
        frame.state.notifyErr("Decrypt: out of memory.");
        return;
    };
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var nbuf: [512]u8 = undefined;
        const new_base = rpgm.decryptedName(&nbuf, std.fs.path.basename(entry.path)) orelse continue;

        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ root, entry.path }) catch continue;

        var dst_buf: [1024]u8 = undefined;
        const rel_dir = std.fs.path.dirname(entry.path);
        const dst_path = if (rel_dir) |d|
            std.fmt.bufPrint(&dst_buf, "{s}/{s}/{s}", .{ root, d, new_base }) catch continue
        else
            std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ root, new_base }) catch continue;

        decryptOne(alloc, io, src_path, dst_path, key) catch |e| {
            log.warn("decrypt {s} failed: {s}", .{ entry.path, @errorName(e) });
            continue;
        };
        count += 1;
    }

    if (count > 0) {
        var msg_buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Decrypted {d} RPGM asset(s) — originals kept.", .{count}) catch "Decrypt complete.";
        frame.state.notifyOk(msg);
    } else {
        frame.state.notifyWarn("No encrypted RPGM assets found.");
    }
}

fn decryptOne(alloc: std.mem.Allocator, io: Io, src: []const u8, dst: []const u8, key: [rpgm.KEY_LEN]u8) !void {
    const data = try Io.Dir.cwd().readFileAlloc(io, src, alloc, .limited(512 * 1024 * 1024));
    defer alloc.free(data);
    const dec = try rpgm.decrypt(alloc, data, key); // NotEncrypted/OutOfMemory
    defer alloc.free(dec);

    var f = try Io.Dir.cwd().createFile(io, dst, .{ .truncate = true });
    defer f.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(dec);
    try fw.interface.flush();
}

/// Locate System.json and parse its encryptionKey. Tries the common MV/MZ
/// locations first, then walks the tree as a fallback.
fn findKey(alloc: std.mem.Allocator, io: Io, root: []const u8) ?[rpgm.KEY_LEN]u8 {
    const candidates = [_][]const u8{
        "www/data/System.json",
        "data/System.json",
        "www/System.json",
        "System.json",
    };
    for (candidates) |rel| {
        if (readKeyAt(alloc, io, root, rel)) |k| return k;
    }

    var dir = Io.Dir.cwd().openDir(io, root, .{ .access_sub_paths = true, .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(alloc) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "System.json")) continue;
        if (readKeyAt(alloc, io, root, entry.path)) |k| return k;
    }
    return null;
}

fn readKeyAt(alloc: std.mem.Allocator, io: Io, root: []const u8, rel: []const u8) ?[rpgm.KEY_LEN]u8 {
    var pbuf: [1024]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ root, rel }) catch return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(8 * 1024 * 1024)) catch return null;
    defer alloc.free(bytes);
    return rpgm.keyFromSystemJson(alloc, bytes);
}
