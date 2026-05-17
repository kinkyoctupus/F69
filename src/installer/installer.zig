// Public face of the installer context.

const dom = @import("domain.zig");
const ovl = @import("overlay.zig");
const trk = @import("tracker.zig");

pub const errors = @import("errors.zig");

pub const InstallLog = dom.InstallLog;
pub const BackupMode = dom.BackupMode;
pub const OverlayMode = dom.OverlayMode;
pub const OverlayBackend = ovl.OverlayBackend;
pub const pickOverlay = ovl.pickBackend;
pub const Tracker = trk.Tracker;

// Public face of `apply.zig` — UI calls these directly.
pub const applyModArchive = @import("apply.zig").applyModArchive;
pub const applyModRecipe = @import("apply.zig").applyModRecipe;
pub const uninstallMod = @import("apply.zig").uninstallMod;
pub const ApplyOpts = @import("apply.zig").ApplyOpts;

pub const mod_archives = @import("mod_archives.zig");
pub const preset_detect = @import("preset_detect.zig");
pub const simulate_mod = @import("simulate.zig");
pub const SimulationResult = simulate_mod.SimulationResult;
pub const simulateInstall = simulate_mod.simulate;

// Test discovery — pull in nested test {} blocks.
test {
    _ = trk;
    _ = @import("apply.zig");
    _ = @import("mod_archives.zig");
    _ = @import("preset_detect.zig");
    _ = @import("simulate.zig");
}
