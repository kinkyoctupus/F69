// WebSocket + JSON-RPC server for an eventual f69-owned browser
// extension. **Deferred to phase 6+** (architect review 2026-05-08).
// Phases 1–5 don't need it: bookmark import, scrape, sync run direct
// from the app process.
//
// When we do build it: bind 127.0.0.1 only (NEVER 0.0.0.0 — XLibrary's
// security flaw). Auto-generated rpc-secret per app start. RFC 6455
// framing in `ws_protocol.zig` (~600 LOC), JSON-RPC 2.0 dispatch in
// `jsonrpc.zig`, method handlers in `handlers.zig`.

const std = @import("std");

pub const PORT: u16 = 8183;
pub const HOST = "127.0.0.1";

pub const Server = struct {
    pub fn run(self: *Server) !void {
        _ = self;
        return error.NotYetImplemented;
    }
};
