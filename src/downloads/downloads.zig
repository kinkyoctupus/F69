// Public API of the downloads context.

const dom = @import("domain.zig");
const mgr = @import("manager.zig");
const hnd = @import("handler.zig");
const arc = @import("archive.zig");
const ver = @import("verify.zig");
const aria2_rpc = @import("aria2_rpc.zig");

pub const errors = @import("errors.zig");

pub const Job = dom.Job;
pub const JobKind = dom.JobKind;
pub const JobStatus = dom.JobStatus;

pub const Manager = mgr.Manager;
pub const Handler = hnd.Handler;

pub const Aria2Daemon = aria2_rpc.Daemon;
pub const Aria2Status = aria2_rpc.Status;

pub const Format = arc.Format;
pub const ExtractOpts = arc.ExtractOpts;
pub const detectFormat = arc.detectFormat;
pub const extract = arc.extract;

pub const Hasher = ver.Hasher;
pub const verifyFile = ver.verifyFile;
pub const hexDecode = ver.hexDecode;

// RPDL is concrete (login + fetchTorrent → bytes → Manager.enqueueTorrent),
// not a vtable Handler. The remaining handlers/ stubs are kept until they
// either get real implementations or are deleted in the mirror-handler
// follow-up round.
pub const rpdl = @import("rpdl.zig");

// Handler factories — callers choose which to register.
pub const handlers = struct {
    pub const http = @import("handlers/http.zig");
    pub const aria2 = @import("handlers/aria2.zig");
    pub const mega = @import("handlers/mega.zig");
    pub const mediafire = @import("handlers/mediafire.zig");
    pub const gofile = @import("handlers/gofile.zig");
    pub const browser = @import("handlers/browser.zig");
};

// Force `zig test` to discover the per-file `test {}` blocks. Without
// these references the compiler only pulls in the symbols re-exported
// above, so nested tests would silently no-op.
test {
    _ = mgr;
    _ = aria2_rpc;
    _ = @import("rpdl.zig");
    _ = arc;
    _ = ver;
}
