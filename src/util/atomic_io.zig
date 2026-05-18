// Atomic file write — tmp + rename so a crash mid-write can never leave
// a partially-written file. Used everywhere the codebase persists state
// (recipe ZON, tracker JSON, settings files, manager_jobs, mod queue,
// tags.txt, …).
//
// The pattern is simple but every site that hand-rolled it added some
// variant of `<path>.tmp` extension + a `defer close` ordering bug
// waiting to happen. Centralising the write removes that surface.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    OutOfMemory,
    WriteFailed,
};

/// Write `bytes` to `path` atomically. Creates parent dirs if missing,
/// writes to `<path>.tmp`, then renames into place. Caller-owned path
/// + bytes (we don't take ownership).
pub fn writeFileAtomic(io: Io, path: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.WriteFailed;
    }

    var tmp_buf: [4096]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return Error.WriteFailed;

    var tmp = std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true }) catch return Error.WriteFailed;
    {
        defer tmp.close(io);
        var fw_buf: [4096]u8 = undefined;
        var fw = tmp.writer(io, &fw_buf);
        fw.interface.writeAll(bytes) catch return Error.WriteFailed;
        fw.interface.flush() catch return Error.WriteFailed;
    }

    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch return Error.WriteFailed;
}

const testing = std.testing;
const test_env = @import("util_test_env");

test "writeFileAtomic: round-trips short content" {
    var env = try test_env.TestEnv.init(testing.allocator, "atomic-io-test");
    defer env.deinit();

    const path = try env.path("out.txt");
    defer testing.allocator.free(path);

    try writeFileAtomic(env.io, path, "hello atomic world\n");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello atomic world\n", bytes);
}

test "writeFileAtomic: overwrite is atomic" {
    var env = try test_env.TestEnv.init(testing.allocator, "atomic-io-overwrite");
    defer env.deinit();

    const path = try env.path("out.txt");
    defer testing.allocator.free(path);

    try writeFileAtomic(env.io, path, "first");
    try writeFileAtomic(env.io, path, "second");

    const bytes = try std.Io.Dir.cwd().readFileAlloc(env.io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("second", bytes);
}
