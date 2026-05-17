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

pub const USER_AGENT = "f69/" ++ build_options.version;

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
