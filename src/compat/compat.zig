// Public face of the compat context. Minimal re-exports per the
// architect convention — callers reach into submodules for anything
// not bound here.

const dom = @import("domain.zig");
pub const errors = @import("errors.zig");

pub const Recipe = dom.Recipe;
pub const Severity = dom.Severity;
pub const Os = dom.Os;
pub const Engine = dom.Engine;
pub const Detect = dom.Detect;
pub const Action = dom.Action;
pub const EnvPrepend = dom.EnvPrepend;
pub const EnvSet = dom.EnvSet;
pub const SystemHint = dom.SystemHint;
pub const DistroHint = dom.DistroHint;
pub const Issue = dom.Issue;
pub const IssueStatus = dom.IssueStatus;
pub const FixRecord = dom.FixRecord;
pub const BackupRecord = dom.BackupRecord;
pub const TouchedPath = dom.TouchedPath;
pub const EnvPair = dom.EnvPair;

const zon = @import("zon_loader.zig");
pub const Parsed = zon.Parsed;
pub const loadPath = zon.loadPath;
pub const parseFromBytes = zon.parseFromBytes;
pub const hashSource = zon.hashSource;

pub const Repo = @import("repository.zig").Repo;
pub const RepoEntry = @import("repository.zig").Entry;
pub const validate = @import("validator.zig").validate;

pub const Host = @import("host.zig").Host;
pub const PackageManager = @import("host.zig").PackageManager;
pub const probeHost = @import("host.zig").probe;

pub const Detector = @import("detect.zig");
pub const matches = Detector.matches;

pub const BackupStore = @import("backup.zig").Store;

pub const Resolver = @import("resources.zig").Resolver;

pub const Service = @import("service.zig").Service;
pub const serializeBackups = @import("service.zig").serializeBackups;
pub const deserializeBackups = @import("service.zig").deserializeBackups;

const apply_mod = @import("apply.zig");
pub const Outcome = apply_mod.Outcome;
pub const applyEnvPairs = apply_mod.applyEnvPairs;

// Re-export tests so they're picked up by the module test run.
test {
    _ = dom;
    _ = @import("zon_loader.zig");
    _ = @import("repository.zig");
    _ = @import("validator.zig");
    _ = @import("host.zig");
    _ = @import("detect.zig");
    _ = @import("backup.zig");
    _ = @import("resources.zig");
    _ = @import("apply.zig");
    _ = @import("service.zig");
}
