// Minimal HTTP helper layered on `std.http.Client`. Consolidates the
// boilerplate that's been re-implemented in 5 places (`f95/client.zig`,
// `f95/auth.zig`, `downloads/rpdl.zig`, `convert/sdk_cache.zig`,
// `downloads/aria2_rpc.zig`):
//
//   - User-agent override from `build_options.version` so a release
//     bump propagates without a 5-file edit.
//   - Single ownership model: caller hands in an arena allocator + io;
//     we own the short-lived `std.http.Client` for the duration of
//     one request.
//   - Status classification: 2xx → ok, 4xx → ClientError, 5xx →
//     ServerError, network failure → NetworkError. Callers branch on
//     a tiny error set instead of re-mapping `error.UnexpectedConnect`.
//
// What this does NOT do:
//   - Streaming downloads — large bodies still go through
//     `Io.Writer.Allocating` at the caller (sdk_cache.fetch streams via
//     a tmp-file Writer for the same reason).
//   - Cookies — `f95/client.zig` keeps its rate-limit + cookie
//     middleware on top of this helper.
//   - Retries — the download manager's fallback chain handles per-source
//     retry at a higher level.

const std = @import("std");
const build_options = @import("build_options");
const ratelimit = @import("util_ratelimit");

const Io = std.Io;

pub const USER_AGENT = "f69/" ++ build_options.version;

// ----- per-host throttle -----
//
// Every one-shot fetch (rpdl, sdk_cache, f95 indexer) shares one process-
// global limiter so we don't hammer an external host from multiple worker
// threads. The F95 client and the aria2 RPC client use their own
// std.http.Client and do NOT go through here, so their cadence is unchanged.

/// Minimum spacing between requests to the same host, in ms. `0` disables
/// throttling entirely (used by tests). Tunable at runtime.
pub var min_interval_ms: u64 = 800;

var g_limiter: ratelimit.PerHostLimiter = .{};
var g_limiter_lock: Io.Mutex = .init;

/// Host component of an http(s) URL — scheme/userinfo/port/path stripped.
/// Pure + testable. Returns "" when no authority is present (the limiter
/// then keys everything under one bucket, which is harmless).
pub fn hostOf(url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    var auth_end: usize = after_scheme.len;
    for (after_scheme, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            auth_end = i;
            break;
        }
    }
    var authority = after_scheme[0..auth_end];
    if (std.mem.indexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (std.mem.indexOfScalar(u8, authority, ':')) |c| authority = authority[0..c];
    return authority;
}

fn isLocal(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

/// Block until this host's next request slot is due, then return. Sleeps
/// outside the lock so concurrent callers each wait their own assigned slot
/// (PerHostLimiter spaces a burst into evenly-staggered slots) rather than
/// serializing on the mutex.
fn throttle(io: Io, url: []const u8) void {
    if (min_interval_ms == 0) return;
    const host = hostOf(url);
    if (isLocal(host)) return;

    // Units cancel in reserve(); work in ms throughout.
    const interval_ms: i128 = @intCast(min_interval_ms);
    g_limiter_lock.lockUncancelable(io);
    const now_ms: i128 = Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
    const wait_ms = g_limiter.reserve(host, now_ms, interval_ms);
    g_limiter_lock.unlock(io);

    if (wait_ms > 0) {
        io.sleep(Io.Duration.fromMilliseconds(@intCast(wait_ms)), .real) catch {};
    }
}

test "hostOf strips scheme, path, port and userinfo" {
    try std.testing.expectEqualStrings("dl.rpdl.net", hostOf("https://dl.rpdl.net/api/login"));
    try std.testing.expectEqualStrings("api.f95checker.dev", hostOf("https://api.f95checker.dev/"));
    try std.testing.expectEqualStrings("example.com", hostOf("http://example.com:8080/path?q=1"));
    try std.testing.expectEqualStrings("host.tld", hostOf("https://user:pass@host.tld/x"));
    try std.testing.expectEqualStrings("bare.host", hostOf("bare.host/no-scheme"));
    try std.testing.expectEqualStrings("a.b", hostOf("https://a.b"));
}

test "isLocal recognises loopback" {
    try std.testing.expect(isLocal("127.0.0.1"));
    try std.testing.expect(isLocal("localhost"));
    try std.testing.expect(!isLocal("dl.rpdl.net"));
}

pub const Error = error{
    NetworkError,
    ClientError,
    ServerError,
    UnexpectedStatus,
    OutOfMemory,
};

pub const Header = std.http.Header;
pub const Method = std.http.Method;

pub const Options = struct {
    method: Method = .GET,
    /// Body to send. Set non-empty for POST/PUT. `null` for bodyless
    /// methods (GET/HEAD).
    payload: ?[]const u8 = null,
    /// Headers added on top of the auto-injected user-agent.
    extra_headers: []const Header = &.{},
    /// Cap on response body size. Network adapter throws on overrun
    /// rather than allocating unbounded memory.
    max_response_bytes: usize = 16 * 1024 * 1024,
    /// Override the user-agent. Defaults to `USER_AGENT` (f69/<version>).
    user_agent: []const u8 = USER_AGENT,
};

pub const Response = struct {
    /// Allocator-owned body. Caller frees.
    body: []u8,
    /// HTTP status code as a u16 (200, 404, etc).
    status: u16,
};

/// One-shot HTTP call. Spins up a short-lived `std.http.Client`, runs
/// the request, returns the body + status. Caller owns `body`.
pub fn fetch(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    opts: Options,
) Error!Response {
    // Space requests to the same external host (no-op for localhost / when
    // min_interval_ms == 0). Blocks the calling worker, never the UI thread.
    throttle(io, url);

    var http: std.http.Client = .{ .allocator = alloc, .io = io };
    defer http.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();

    const result = http.fetch(.{
        .location = .{ .url = url },
        .method = opts.method,
        .response_writer = &aw.writer,
        .payload = opts.payload,
        .headers = .{ .user_agent = .{ .override = opts.user_agent } },
        .extra_headers = opts.extra_headers,
        .keep_alive = false,
    }) catch {
        aw.deinit();
        return Error.NetworkError;
    };

    const status_u16: u16 = @intFromEnum(result.status);
    const body = aw.toOwnedSlice() catch return Error.OutOfMemory;
    if (body.len > opts.max_response_bytes) {
        alloc.free(body);
        return Error.UnexpectedStatus;
    }

    return .{ .body = body, .status = status_u16 };
}

/// Convenience: GET that returns the body + verifies a 2xx status.
/// Non-2xx → error (caller can't see the body in this path; use
/// `fetch` directly when you need the error body).
pub fn get(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) Error![]u8 {
    const resp = try fetch(alloc, io, url, .{});
    if (resp.status >= 200 and resp.status < 300) return resp.body;
    alloc.free(resp.body);
    if (resp.status >= 400 and resp.status < 500) return Error.ClientError;
    if (resp.status >= 500) return Error.ServerError;
    return Error.UnexpectedStatus;
}
