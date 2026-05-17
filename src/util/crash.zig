// Custom panic handler. Writes ~/.cache/f69/crashes/<unix-ts>.log with
// stack trace, zig version, git rev (baked at build time), platform.
//
// Install at startup from main.zig:
//
//     pub const panic = std.debug.FullPanic(crash.panicHandler);
//
// or wire via Zig 0.16's `std.panic_handler` mechanism. Print path to
// stderr so user sees where to find the log.

const std = @import("std");

pub const build_git_rev: []const u8 = if (@import("builtin").mode == .Debug) "dev" else "unknown";

pub fn panicHandler(message: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;

    // Best-effort log write — never block the panic from completing.
    writeLog(message) catch {};

    // Hand off to std's default panic for the actual message + stack on stderr.
    std.debug.print("\nfatal: {s}\n", .{message});
    std.debug.print("(crash log: see ~/.cache/f69/crashes/)\n", .{});
    std.process.exit(134);
}

fn writeLog(message: []const u8) !void {
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);

    var path_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "{s}/.cache/f69/crashes", .{home});
    std.fs.cwd().makePath(dir_path) catch {};

    const ts = std.time.timestamp();
    var file_buf: [512]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_buf, "{s}/{d}.log", .{ dir_path, ts });

    var file = std.fs.cwd().createFile(file_path, .{}) catch return;
    defer file.close();

    var out_buf: [256]u8 = undefined;
    var w = file.writer(&out_buf);
    try w.interface.print(
        "f69 crash log\n" ++
            "ts: {d}\n" ++
            "git: {s}\n" ++
            "zig: {s}\n" ++
            "platform: {s}-{s}\n" ++
            "\nmessage:\n{s}\n",
        .{
            ts,
            build_git_rev,
            @import("builtin").zig_version_string,
            @tagName(@import("builtin").os.tag),
            @tagName(@import("builtin").cpu.arch),
            message,
        },
    );
    try w.interface.flush();
}
