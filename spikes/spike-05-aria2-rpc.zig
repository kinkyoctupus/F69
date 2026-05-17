// spike-05: drive aria2c via the JSON-RPC daemon manager, through
// the higher-level `downloads.Manager` API (lazy-spawn + enqueue/tick).
//
// Spawns a fresh aria2c on a random port + secret, queues one URL,
// polls Manager.tick() until the job reaches a terminal state.
//
// Usage (inside `nix develop`):
//   zig build spike-aria2-rpc -- "https://speed.cloudflare.com/__down?bytes=131072"
//   zig build spike-aria2-rpc        # uses a default test URL
//
// Files land in /tmp/f69-aria2-spike/.

const std = @import("std");
const downloads = @import("downloads");

const DEFAULT_URL = "https://speed.cloudflare.com/__down?bytes=131072";
const DOWNLOAD_DIR = "/tmp/f69-aria2-spike";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const url: []const u8 = if (args.len >= 2) args[1] else DEFAULT_URL;

    try std.Io.Dir.cwd().createDirPath(io, DOWNLOAD_DIR);

    var mgr = downloads.Manager.init(gpa, io, DOWNLOAD_DIR, DOWNLOAD_DIR, "aria2c");
    defer mgr.deinit();

    std.debug.print("[spike-05] enqueue: {s}\n", .{url});
    const job_id = try mgr.enqueueUrl(url, .game, 0, null, null);
    std.debug.print("[spike-05] job id = {d}\n", .{job_id});

    var iter: u32 = 0;
    while (iter < 200) : (iter += 1) {
        mgr.tick();
        const j = mgr.statusOf(job_id) orelse {
            std.debug.print("[spike-05] job {d} disappeared!\n", .{job_id});
            return;
        };

        const total = j.bytes_total orelse 0;
        const pct: u32 = if (total == 0) 0 else @intCast(@divTrunc(j.bytes_done * 100, total));
        std.debug.print(
            "[spike-05] {s}  {d}/{d}  ({d}%)\n",
            .{ @tagName(j.status), j.bytes_done, total, pct },
        );

        switch (j.status) {
            .done => {
                std.debug.print("[spike-05] DONE — file in {s}\n", .{DOWNLOAD_DIR});
                return;
            },
            .failed => {
                std.debug.print(
                    "[spike-05] FAILED — {s}\n",
                    .{j.error_msg orelse "(no message)"},
                );
                return;
            },
            .cancelled => {
                std.debug.print("[spike-05] CANCELLED\n", .{});
                return;
            },
            else => {},
        }
        io.sleep(std.Io.Duration.fromMilliseconds(250), .real) catch {};
    }
    std.debug.print("[spike-05] timed out after 50s\n", .{});
}
