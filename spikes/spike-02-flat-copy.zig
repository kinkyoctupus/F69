// spike-02: flat-copy a mod over a base, with a file tracker for clean
// uninstall. Throwaway PoC. Goal: validate the tracker design before
// sinking phase-7 effort into `installer/{apply,tracker,overlay}.zig`.
//
// Behavior:
//   apply    — wipe dest, cp base→dest, then walk mod tree:
//                - file missing in dest → copy, log .added
//                - file existing → preserve to .f69-trash/<sha256>, then
//                  overwrite, log .overwritten with pre-image hash
//              Final install log written as line-delimited JSON to
//              <dest>/.install.log.
//
//   rollback — read .install.log in reverse:
//                - .added entries deleted
//                - .overwritten entries restored from .f69-trash/<sha256>
//              .install.log + .f69-trash/ removed.
//
// Built against Zig 0.16's std.Io API.
//
// Usage:
//   zig build spike-flat-copy -- apply <base> <mod> <dest>
//   zig build spike-flat-copy -- rollback <dest>

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage(io);

    if (std.mem.eql(u8, args[1], "apply")) {
        if (args.len != 5) return usage(io);
        try doApply(io, gpa, arena, args[2], args[3], args[4]);
    } else if (std.mem.eql(u8, args[1], "rollback")) {
        if (args.len != 3) return usage(io);
        try doRollback(io, gpa, arena, args[2]);
    } else {
        try usage(io);
    }
}

fn usage(io: Io) !void {
    try Io.File.stdout().writeStreamingAll(io,
        \\spike-02-flat-copy
        \\
        \\usage:
        \\  spike-flat-copy apply <base_dir> <mod_dir> <dest_dir>
        \\  spike-flat-copy rollback <dest_dir>
        \\
    );
}

// ============================================================
//  apply
// ============================================================

const LogEntryKind = enum { from_base, added, overwritten };

const LogEntry = struct {
    kind: LogEntryKind,
    rel_path: []const u8,
    /// sha256 of pre-image (only for .overwritten). Hex.
    preimage_sha256: ?[64]u8 = null,
};

fn doApply(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base_dir: []const u8,
    mod_dir: []const u8,
    dest_dir: []const u8,
) !void {
    try printf(io, "[spike] apply base={s} mod={s} dest={s}\n", .{ base_dir, mod_dir, dest_dir });

    // 1. Clean dest. deleteTree returns success when path is absent, so
    //    no special handling needed.
    try Io.Dir.cwd().deleteTree(io, dest_dir);
    try Io.Dir.cwd().createDirPath(io, dest_dir);

    const trash_path = try std.fmt.allocPrint(arena, "{s}/.f69-trash", .{dest_dir});
    try Io.Dir.cwd().createDirPath(io, trash_path);

    var log: std.ArrayList(LogEntry) = .empty;
    defer log.deinit(arena);

    // 2. Copy base → dest. Each file logged as .from_base.
    try copyTree(io, gpa, arena, base_dir, dest_dir, &log, .from_base, null);

    // 3. Apply mod tree on top.
    try copyTree(io, gpa, arena, mod_dir, dest_dir, &log, .added, trash_path);

    // 4. Write install log.
    const log_path = try std.fmt.allocPrint(arena, "{s}/.install.log", .{dest_dir});
    try writeLog(io, gpa, log_path, log.items);

    // 5. Summary.
    var c_base: usize = 0;
    var c_added: usize = 0;
    var c_over: usize = 0;
    for (log.items) |e| switch (e.kind) {
        .from_base => c_base += 1,
        .added => c_added += 1,
        .overwritten => c_over += 1,
    };
    try printf(io,
        "[spike] done: {d} from base, {d} added by mod, {d} overwritten by mod\n",
        .{ c_base, c_added, c_over },
    );
    try printf(io, "[spike] log:    {s}\n", .{log_path});
    try printf(io, "[spike] trash:  {s}/  ({d} pre-images)\n", .{ trash_path, c_over });
}

/// Walk `src` recursively. For each file:
///   - rel path = path relative to src
///   - dest_path = dest_dir/rel
///   - if dest_path exists already (only happens during the mod pass),
///     hash its current content, copy it to <trash_dir>/<sha256>, log
///     LogEntry{ .kind=.overwritten, .rel_path=rel, .preimage_sha256=hash }.
///   - otherwise log LogEntry{ .kind=base_kind, .rel_path=rel }.
///   - then copy src→dest.
///
/// `base_kind` is the kind to use for non-overwriting writes (.from_base
/// for the base pass; .added for the mod pass).
fn copyTree(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root: []const u8,
    dest_root: []const u8,
    log: *std.ArrayList(LogEntry),
    base_kind: LogEntryKind,
    trash_dir: ?[]const u8,
) !void {
    var src = try Io.Dir.cwd().openDir(io, src_root, .{ .access_sub_paths = true, .iterate = true });
    defer src.close(io);

    var walker = try src.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const rel = try arena.dupe(u8, entry.path);
        const dest_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest_root, rel });

        // Ensure parent dirs exist.
        if (std.fs.path.dirname(dest_path)) |d| try Io.Dir.cwd().createDirPath(io, d);

        // If the destination file already exists, this is a mod
        // overwriting a base file. Hash the pre-image, save to trash.
        const exists = blk: {
            Io.Dir.cwd().access(io, dest_path, .{}) catch |e| switch (e) {
                error.FileNotFound => break :blk false,
                else => return e,
            };
            break :blk true;
        };

        if (exists) {
            std.debug.assert(trash_dir != null);
            const hash_hex = try hashFile(io, gpa, dest_path);
            const trash_target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ trash_dir.?, hash_hex[0..] });
            // Move pre-image into trash. Use rename (atomic, same fs) and
            // fall back to copy+delete if the trash is on a different fs.
            Io.Dir.cwd().rename(dest_path, Io.Dir.cwd(), trash_target, io) catch {
                try copyFile(io, gpa, arena, dest_path, trash_target);
                try Io.Dir.cwd().deleteFile(io, dest_path);
            };
            try log.append(arena, .{
                .kind = .overwritten,
                .rel_path = rel,
                .preimage_sha256 = hash_hex,
            });
        } else {
            try log.append(arena, .{ .kind = base_kind, .rel_path = rel });
        }

        // Copy the source file to dest.
        const src_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_root, rel });
        try copyFile(io, gpa, arena, src_path, dest_path);
    }
}

fn copyFile(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    _ = arena;
    const data = try Io.Dir.cwd().readFileAlloc(io, src, gpa, .unlimited);
    defer gpa.free(data);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = data });
}

fn hashFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ![64]u8 {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(data);
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sha, .{});
    return std.fmt.bytesToHex(sha, .lower);
}

fn writeLog(io: Io, gpa: std.mem.Allocator, path: []const u8, entries: []const LogEntry) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (entries) |e| {
        try buf.print(gpa, "{{\"kind\":\"{s}\",\"path\":\"{s}\"", .{ @tagName(e.kind), e.rel_path });
        if (e.preimage_sha256) |h| {
            try buf.print(gpa, ",\"preimage_sha256\":\"{s}\"", .{h[0..]});
        }
        try buf.appendSlice(gpa, "}\n");
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

// ============================================================
//  rollback
// ============================================================

fn doRollback(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dest_dir: []const u8) !void {
    try printf(io, "[spike] rollback dest={s}\n", .{dest_dir});

    const log_path = try std.fmt.allocPrint(arena, "{s}/.install.log", .{dest_dir});
    const trash = try std.fmt.allocPrint(arena, "{s}/.f69-trash", .{dest_dir});

    const log_data = Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .unlimited) catch |e| switch (e) {
        error.FileNotFound => {
            try printf(io, "[spike] no install log at {s} — nothing to roll back\n", .{log_path});
            return;
        },
        else => return e,
    };
    defer gpa.free(log_data);

    // Walk log lines in reverse so most-recent overwrites are restored
    // before the base files are removed.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);
    var it = std.mem.splitScalar(u8, log_data, '\n');
    while (it.next()) |ln| {
        if (ln.len > 0) try lines.append(arena, ln);
    }

    var i: usize = lines.items.len;
    var n_added_removed: usize = 0;
    var n_restored: usize = 0;
    while (i > 0) {
        i -= 1;
        const line = lines.items[i];
        const kind = jsonField(line, "kind") orelse continue;
        const rel = jsonField(line, "path") orelse continue;
        const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest_dir, rel });

        if (std.mem.eql(u8, kind, "overwritten")) {
            const hash = jsonField(line, "preimage_sha256") orelse continue;
            const tpath = try std.fmt.allocPrint(arena, "{s}/{s}", .{ trash, hash });
            // Restore pre-image, replacing the mod file.
            Io.Dir.cwd().deleteFile(io, target) catch {};
            try Io.Dir.cwd().rename(tpath, Io.Dir.cwd(), target, io);
            n_restored += 1;
        } else if (std.mem.eql(u8, kind, "added")) {
            Io.Dir.cwd().deleteFile(io, target) catch {};
            n_added_removed += 1;
        } // .from_base entries: leave them; rollback only undoes the mod layer.
    }

    // Cleanup: remove trash + log so the install dir is clean.
    Io.Dir.cwd().deleteTree(io, trash) catch {};
    Io.Dir.cwd().deleteFile(io, log_path) catch {};

    try printf(io, "[spike] rollback done: {d} mod-added removed, {d} pre-images restored\n",
        .{ n_added_removed, n_restored });
}

// Quick-and-dirty JSON field extractor for our simple log lines.
// Returns the slice of the value, or null. Only handles "key":"value" form
// where value is alphanumeric/path-friendly with no escapes — fine for us.
fn jsonField(line: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    const value_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, value_start, '"') orelse return null;
    return line[value_start..end];
}

// ============================================================
//  helpers
// ============================================================

fn printf(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
    try Io.File.stdout().writeStreamingAll(io, out);
}
