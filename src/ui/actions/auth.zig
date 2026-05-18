// F95 + RPDL login / logout — synchronous on the UI thread (~1-2s
// for the GET-token + POST-creds dance). Phase 6+ will move these
// onto worker threads with the same atomic-flag pattern as
// `syncGame`. Cookies / tokens are persisted to disk on success so
// the next launch picks them up without a re-login.

const std = @import("std");
const log = std.log.scoped(.ui_actions);
const f95 = @import("f95");
const downloads = @import("downloads");
const types = @import("../types.zig");

const Frame = types.Frame;

// ============================================================
//  F95 login / logout
// ============================================================

/// Synchronous login from the UI thread. Blocks for ~1-2s while the
/// GET-token + POST-creds dance runs. Phase 6+ moves this onto a
/// worker thread with the same atomic-flag pattern as `syncGame`.
///
/// Persists the cookie to `frame.info.cookie_path` on success so the
/// next launch comes up authenticated.
pub fn doLogin(frame: *Frame, username: []const u8, password: []const u8) void {
    const state = frame.state;
    if (username.len == 0 or password.len == 0) {
        state.login_status = .err;
        state.setLoginMsg("username and password required");
        return;
    }
    log.info("doLogin start (user='{s}')", .{username});
    state.login_status = .logging_in;
    state.setLoginMsg("contacting F95Zone…");

    const cookie = frame.f95_svc.login(frame.io, .{
        .username = username,
        .password = password,
    }) catch |e| {
        state.login_status = .err;
        const friendly: []const u8 = switch (e) {
            error.AuthRequired => "incorrect username or password (or 2FA — not supported yet)",
            error.NetworkError => "network error — check connection",
            error.HttpStatusError => "F95Zone returned an unexpected status",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "login failed: {s}", .{friendly}) catch "login failed";
        state.setLoginMsg(m);
        return;
    };
    defer frame.lib.alloc.free(cookie);

    persistCookie(frame.io, frame.info.cookie_path, cookie) catch |e| {
        std.log.scoped(.ui).warn("could not persist cookie: {s}", .{@errorName(e)});
    };

    // Wipe the password buffer so it doesn't linger in State.
    @memset(&state.f95_pass_buf, 0);
    state.login_status = .logged_in;
    state.setLoginMsg("logged in");
}

pub fn doLogout(frame: *Frame) void {
    const state = frame.state;
    // Wipe in-memory cookie on the f95 client via the lock-protected
    // helper. Workers snapshot the cookie under cookie_lock; doing the
    // clear via that helper closes the UAF window where a worker
    // could read a freed slice if logout ran between snapshot dup
    // and snapshot use. Also frees with the client's own allocator
    // rather than lib.alloc (currently the same gpa, but no longer
    // a load-bearing assumption).
    frame.f95_svc.client.clearCookie();
    // Best-effort delete the on-disk cookie.
    std.Io.Dir.cwd().deleteFile(frame.io, frame.info.cookie_path) catch {};
    @memset(&state.f95_user_buf, 0);
    @memset(&state.f95_pass_buf, 0);
    state.login_status = .logged_out;
    state.setLoginMsg("logged out");
}

// ============================================================
//  RPDL login — mirrors doLogin / doLogout but for dl.rpdl.net
// ============================================================

pub fn doRpdlLogin(frame: *Frame, username: []const u8, password: []const u8) void {
    const state = frame.state;
    if (username.len == 0 or password.len == 0) {
        state.rpdl_status = .err;
        state.setRpdlMsg("username and password required");
        return;
    }
    log.info("doRpdlLogin start (user='{s}')", .{username});
    state.rpdl_status = .logging_in;
    state.setRpdlMsg("contacting RPDL…");

    const token = downloads.rpdl.login(frame.lib.alloc, frame.io, username, password) catch |e| {
        state.rpdl_status = .err;
        const friendly: []const u8 = switch (e) {
            error.AuthRequired => "incorrect username or password",
            error.NetworkError => "network error — check connection",
            else => @errorName(e),
        };
        var emsg: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&emsg, "login failed: {s}", .{friendly}) catch "login failed";
        state.setRpdlMsg(m);
        return;
    };

    persistRpdlToken(frame.io, frame.info.rpdl_token_path, token) catch |e| {
        std.log.scoped(.ui).warn("could not persist rpdl token: {s}", .{@errorName(e)});
    };

    // Drop any prior token + take ownership of the new one.
    if (state.rpdl_token) |old| frame.lib.alloc.free(old);
    state.rpdl_token = token;

    @memset(&state.rpdl_pass_buf, 0);
    state.rpdl_status = .logged_in;
    state.setRpdlMsg("logged in");
}

pub fn doRpdlLogout(frame: *Frame) void {
    const state = frame.state;
    if (state.rpdl_token) |old| {
        frame.lib.alloc.free(old);
        state.rpdl_token = null;
    }
    std.Io.Dir.cwd().deleteFile(frame.io, frame.info.rpdl_token_path) catch {};
    @memset(&state.rpdl_user_buf, 0);
    @memset(&state.rpdl_pass_buf, 0);
    state.rpdl_status = .logged_out;
    state.setRpdlMsg("logged out");
}

fn persistRpdlToken(io: std.Io, path: []const u8, token: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [1024]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var tmp = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer tmp.close(io);
    try tmp.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    var fw_buf: [4096]u8 = undefined;
    var fw = tmp.writer(io, &fw_buf);
    try fw.interface.writeAll(token);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Atomically write the cookie to disk with mode 0600. Tmp+rename
/// keeps a half-written file from confusing the next startup.
fn persistCookie(io: std.Io, path: []const u8, cookie: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer f.close(io);
    var fw_buf: [1024]u8 = undefined;
    var fw = f.writer(io, &fw_buf);
    try fw.interface.writeAll(cookie);
    try fw.interface.flush();
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}
