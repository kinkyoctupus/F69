//! WebSocket transport for aria2 JSON-RPC (karlseguin/websocket.zig).
//!
//! Seed module — currently just verifies the dependency compiles on our Zig
//! and pins the client type/connect config we'll build the transport on.
//! The full Transport vtable impl (read-loop thread → event queue, call()
//! request/response correlation) lands next.

const std = @import("std");
const websocket = @import("websocket");

pub const Client = websocket.Client;

/// Connect config for a local aria2 RPC endpoint.
pub const Endpoint = struct {
    host: []const u8 = "127.0.0.1",
    port: u16,
    /// RPC path; aria2 serves JSON-RPC at /jsonrpc.
    path: []const u8 = "/jsonrpc",
};

test "websocket dependency compiles on this zig toolchain" {
    // Referencing the Client type forces the dependency to compile.
    try std.testing.expect(@hasDecl(Client, "init"));
    try std.testing.expect(@hasDecl(Client, "read"));
    try std.testing.expect(@hasDecl(Client, "writeText"));
}
