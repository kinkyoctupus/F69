// Sandboxie Plus integration. User installs Sandboxie themselves; we
// shell out to `Start.exe /box:<box> <command>`.
//
// Box name: `f69_<f95-thread-id>` (per game, shared across versions so
// saves carry. Sandboxie's COW namespace is rooted at
// `C:\Sandbox\<user>\<box>\drive\C\…`).
//
// Detection priority:
//   1. HKLM\SOFTWARE\Sandboxie InstallPath
//   2. %ProgramFiles%\Sandboxie-Plus\Start.exe
//   3. config-overridden path
//
// `sbiectrl /reload` while another box is running can race. Wrap config
// rewrite + reload in a process-level lock (file lock at
// `%LOCALAPPDATA%\f69\sandboxie.lock`).

const std = @import("std");
const errs = @import("errors.zig");
const dom = @import("domain.zig");

pub const Sandboxie = struct {
    start_exe: []const u8, // resolved Start.exe path

    pub fn detect(alloc: std.mem.Allocator) ?Sandboxie {
        _ = alloc;
        return null; // TODO
    }

    pub fn launch(self: *Sandboxie, alloc: std.mem.Allocator, cfg: dom.SandboxConfig) errs.Error!dom.SpawnResult {
        _ = self;
        _ = alloc;
        _ = cfg;
        return errs.Error.LaunchFailed; // TODO
    }
};
