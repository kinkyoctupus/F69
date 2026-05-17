// InstallerService — orchestrates download → verify → extract → overlay
// → library state update. This is the one context where a Service layer
// earns its keep: it touches `library`, `downloads`, `recipe`, `resolver`,
// and the local `overlay` + `tracker` modules together.

const std = @import("std");
const errs = @import("errors.zig");
const library = @import("library");
const recipe = @import("recipe");
const resolver = @import("resolver");
const downloads = @import("downloads");

const apply = @import("apply.zig");
const overlay_mod = @import("overlay.zig");
const Tracker = @import("tracker.zig").Tracker;

pub const Service = struct {
    alloc: std.mem.Allocator,
    lib: *library.Library,
    dl: *downloads.Service,

    pub fn init(alloc: std.mem.Allocator, lib: *library.Library, dl: *downloads.Service) Service {
        return .{ .alloc = alloc, .lib = lib, .dl = dl };
    }

    /// Install a base game from its recipe. Creates a new Install row
    /// keyed by (game_thread_id, version). Old versions left intact.
    pub fn installGame(self: *Service, g: *const recipe.GameRecipe) errs.Error!library.Install {
        _ = self;
        _ = g;
        return errs.Error.PlanInvalid; // TODO
    }

    /// Apply a resolved mod plan to an install. Rebuilds the overlay
    /// (or flat copy) atomically.
    pub fn applyMods(
        self: *Service,
        install: *const library.Install,
        plan: *const resolver.Plan,
    ) errs.Error!void {
        _ = self;
        _ = install;
        _ = plan;
        return errs.Error.PlanInvalid; // TODO
    }

    /// Roll back an install — reads .install.log, reverses every entry.
    pub fn uninstall(self: *Service, install: *const library.Install) errs.Error!void {
        _ = self;
        _ = install;
        return errs.Error.UninstallFailed; // TODO
    }
};
