// Recipe types — populated by `std.zon.parse` from `.zon` files on disk.
// No custom AST; ZON deserializes directly into these structs.
//
// Anti-RCE is structural: there's no `run` / `exec` / `script` variant
// in InstallStep. The schema simply doesn't allow representing arbitrary
// code execution in a recipe.

const std = @import("std");

pub const Hash = struct {
    sha256: []const u8, // 64 hex chars
};

pub const MirrorHost = enum {
    f95_attachment,
    mega,
    mediafire,
    gofile,
    pixeldrain,
    workupload,
    nopy,
    zippyshare,
    other,
};

pub const Source = union(enum) {
    rpdl: struct { id: u64, sha256: []const u8 },
    ddl: struct { url: []const u8, sha256: []const u8 },
    mirror: struct {
        url: []const u8,
        host: MirrorHost,
        label: ?[]const u8 = null,
        sha256: ?[]const u8 = null,
    },
};

pub const InstallStep = union(enum) {
    extract: struct { to: []const u8, strip: u8 = 0 },
    /// Extract a nested archive that lives inside the main modfile's
    /// staged tree. `archive` is a path relative to the staging dir
    /// (i.e. inside the extracted main archive). For "double-packaged"
    /// mods that ship `outer.zip → inner.zip → game files`.
    extract_inner: struct { archive: []const u8, to: []const u8, strip: u8 = 0 },
    copy: struct { src: []const u8, dest: []const u8 },
    /// Rename / relocate. `src` is relative to the install root after
    /// previous steps; covers both "move file to other folder" and
    /// "rename in place" (same parent dir).
    move: struct { src: []const u8, dest: []const u8 },
    delete: struct { path: []const u8 },
    /// Mark paths executable. Skipped on Windows by the installer; the
    /// step in the recipe stays platform-agnostic.
    chmod_x: struct { paths: []const []const u8 },
    // No run/exec/script. Anti-RCE by schema.
};

pub const Engine = enum {
    renpy,
    rpgm_mv,
    rpgm_mz,
    unity,
    unknown,
};

pub const ConvertSpec = union(enum) {
    none: void,
    renpy: struct {
        /// null = let convert/renpy.detectVersion read it from
        /// `renpy/__init__.py` / `vc_version.py` at convert time.
        sdk_version: ?[]const u8 = null,
    },
    rpgm: struct {
        nwjs_version: ?[]const u8 = null, // null = auto-detect from binary
        ffmpeg_codecs: bool = true,
        bundle_syslibs: bool = true,
    },
};

pub const SandboxBlock = struct {
    network: bool = true,
    bind_extra: []const []const u8 = &.{},
};

pub const UpdateStrategy = enum {
    new_install, // default — new dir per version, keep old
    replace,
    overlay,
    patch,
};

pub const SavesPaths = struct {
    linux: ?[]const u8 = null,
    windows: ?[]const u8 = null,
};

pub const Launch = struct {
    linux: ?[]const u8 = null,
    windows: ?[]const u8 = null,
};

pub const VersionConstraint = struct {
    raw: []const u8, // e.g. ">=0.20,<0.21" — parsed lazily
};

/// Game recipe — minimal manifest. Identity + sources (informational
/// download links for sharing) + optional custom install steps. Fields
/// that used to live here were either:
///   - Auto-derived at runtime (engine_version, convert spec, launch
///     path, save paths) — handled by `convert/detect.zig`,
///     `actions.findLinuxLauncher`, engine handlers.
///   - User preferences, not recipe-author calls (sandbox.network,
///     bind_extra, update strategy, prune policy) — moved to
///     per-game DB / global settings.
///
/// Net effect: a hand-authored recipe is short, portable, and carries
/// only information that's meaningfully per-game-and-author. Convert,
/// launch, sandbox, save paths are environment-specific decisions.
pub const GameRecipe = struct {
    id: []const u8,
    name: []const u8,
    f95_thread: u64,
    /// Canonical install target for this recipe. Also the upper bound
    /// of the implicit compatibility window when `min_version` /
    /// `max_version` aren't set.
    version: []const u8,
    /// Optional inclusive lower bound on the game versions this recipe
    /// applies to. Lets one recipe cover a span of releases when
    /// nothing about the install changed between them.
    /// Null → only matches `version` exactly.
    min_version: ?[]const u8 = null,
    /// Optional inclusive upper bound. Null → defaults to `version`.
    max_version: ?[]const u8 = null,
    /// Engine tag — drives detection-vs-pin shortcuts and the
    /// convert-preset matcher. Detection at install time can also
    /// populate this; recipe just provides the hint.
    engine: Engine = .unknown,

    /// Informational download links. Recipe authors list where the
    /// game can be fetched (RPDL / DDL / mirrors with optional
    /// sha256). The UI surfaces them as clickable links — f69 does
    /// NOT silently auto-fetch from this field; the user picks one.
    sources: []const Source = &.{},
    /// Optional custom install steps. Empty = default "extract
    /// archive at install_dir" behavior. Same closed-set tagged
    /// union used by mod recipes — extract / extract_inner / copy /
    /// move / delete / chmod_x only, no run/exec.
    install: []const InstallStep = &.{},
};

pub const ModConstraint = struct {
    target: []const u8,
    version: ?[]const u8 = null,
};

pub const Provided = struct {
    capability: []const u8,
    version: ?[]const u8 = null,
};

pub const ModRecipe = struct {
    id: []const u8,
    name: []const u8,
    f95_thread: u64,
    /// Full URL to the thread/page where the user can fetch the mod
    /// (typically the F95Zone thread, but recipe authors may point at
    /// any host). Surfaced in the UI as a clickable link so users can
    /// find the download once recipes are shared via a future repo.
    post_url: ?[]const u8 = null,
    version: []const u8,
    for_game: []const u8,
    /// Single target game-version this mod was authored against.
    /// Treated as both bounds of the compatibility range when
    /// `for_game_version_min` / `for_game_version_max` are null.
    for_game_version: ?[]const u8 = null,
    /// Inclusive lower bound on the game versions this mod accepts.
    /// Null → falls back to `for_game_version`. Set together with
    /// `for_game_version_max` to express "valid from X to Y".
    for_game_version_min: ?[]const u8 = null,
    /// Inclusive upper bound. Null → falls back to `for_game_version`
    /// (or unbounded above when both are null and `for_game_version`
    /// is also null).
    for_game_version_max: ?[]const u8 = null,

    requires: []const ModConstraint = &.{},
    conflicts: []const []const u8 = &.{},
    provides: []const Provided = &.{},
    load_after: []const []const u8 = &.{},
    load_before: []const []const u8 = &.{},

    /// Informational only — where the user can fetch the archive
    /// (mods are never auto-downloaded; the user supplies the file
    /// via "Add modfile…").
    sources: []const Source = &.{},
    /// Paths (relative to the install root) this mod will write.
    /// Used for pre-flight conflict detection against other installed
    /// mods' tracker entries.
    files: []const []const u8 = &.{},
    install: []const InstallStep = &.{},
};

pub const RecipeKind = enum { game, mod };
pub const Recipe = union(RecipeKind) {
    game: GameRecipe,
    mod: ModRecipe,
};

const util_version = @import("util_version");

/// Generic inclusive-range check used by both game- and mod-recipe
/// compatibility tests. `min`/`max` null → unbounded on that side.
/// `version` is the game version being checked. Returns true when
/// the version falls inside [min, max].
fn versionInRange(version: []const u8, min: ?[]const u8, max: ?[]const u8) bool {
    if (min) |m| {
        if (util_version.compare(version, m) == .lt) return false;
    }
    if (max) |m| {
        if (util_version.compare(version, m) == .gt) return false;
    }
    return true;
}

/// True when a GameRecipe is intended to apply to `game_version`.
/// Order of precedence:
///   1. If `min_version` or `max_version` is set → range check
///      ([min ?? version, max ?? version]).
///   2. Else → exact match against `recipe.version`.
pub fn gameRecipeAppliesTo(recipe: *const GameRecipe, game_version: []const u8) bool {
    if (recipe.min_version != null or recipe.max_version != null) {
        const lo = recipe.min_version orelse recipe.version;
        const hi = recipe.max_version orelse recipe.version;
        return versionInRange(game_version, lo, hi);
    }
    return std.mem.eql(u8, recipe.version, game_version);
}

/// True when a ModRecipe is intended to apply to `game_version`.
/// Order of precedence:
///   1. Either `for_game_version_min`/`max` set → range check with the
///      missing side falling back to `for_game_version`.
///   2. Else `for_game_version` set → exact match against it.
///   3. Else → no game-version constraint declared → applies to any.
pub fn modRecipeAppliesTo(recipe: *const ModRecipe, game_version: []const u8) bool {
    if (recipe.for_game_version_min != null or recipe.for_game_version_max != null) {
        const lo = recipe.for_game_version_min orelse recipe.for_game_version;
        const hi = recipe.for_game_version_max orelse recipe.for_game_version;
        return versionInRange(game_version, lo, hi);
    }
    if (recipe.for_game_version) |fgv| return std.mem.eql(u8, fgv, game_version);
    return true;
}

test "gameRecipeAppliesTo: exact match without range" {
    const r: GameRecipe = .{ .id = "x", .name = "X", .f95_thread = 1, .version = "0.20" };
    try std.testing.expect(gameRecipeAppliesTo(&r, "0.20"));
    try std.testing.expect(!gameRecipeAppliesTo(&r, "0.21"));
}

test "gameRecipeAppliesTo: explicit range covers span" {
    const r: GameRecipe = .{
        .id = "x",
        .name = "X",
        .f95_thread = 1,
        .version = "0.20",
        .min_version = "0.18",
        .max_version = "0.22",
    };
    try std.testing.expect(gameRecipeAppliesTo(&r, "0.18"));
    try std.testing.expect(gameRecipeAppliesTo(&r, "0.20"));
    try std.testing.expect(gameRecipeAppliesTo(&r, "0.22"));
    try std.testing.expect(!gameRecipeAppliesTo(&r, "0.17"));
    try std.testing.expect(!gameRecipeAppliesTo(&r, "0.23"));
}

test "gameRecipeAppliesTo: one-sided range falls back to version" {
    const r: GameRecipe = .{
        .id = "x",
        .name = "X",
        .f95_thread = 1,
        .version = "0.20",
        .min_version = "0.18",
    };
    // max defaults to recipe.version = 0.20
    try std.testing.expect(gameRecipeAppliesTo(&r, "0.18"));
    try std.testing.expect(gameRecipeAppliesTo(&r, "0.20"));
    try std.testing.expect(!gameRecipeAppliesTo(&r, "0.21"));
}

test "modRecipeAppliesTo: exact for_game_version" {
    const r: ModRecipe = .{ .id = "m", .name = "M", .f95_thread = 1, .version = "1.0", .for_game = "g", .for_game_version = "0.20" };
    try std.testing.expect(modRecipeAppliesTo(&r, "0.20"));
    try std.testing.expect(!modRecipeAppliesTo(&r, "0.21"));
}

test "modRecipeAppliesTo: range overrides exact" {
    const r: ModRecipe = .{
        .id = "m",
        .name = "M",
        .f95_thread = 1,
        .version = "1.0",
        .for_game = "g",
        .for_game_version_min = "0.18",
        .for_game_version_max = "0.22",
    };
    try std.testing.expect(modRecipeAppliesTo(&r, "0.18"));
    try std.testing.expect(modRecipeAppliesTo(&r, "0.22"));
    try std.testing.expect(!modRecipeAppliesTo(&r, "0.17"));
}

test "modRecipeAppliesTo: no constraint → any version" {
    const r: ModRecipe = .{ .id = "m", .name = "M", .f95_thread = 1, .version = "1.0", .for_game = "g" };
    try std.testing.expect(modRecipeAppliesTo(&r, "0.20"));
    try std.testing.expect(modRecipeAppliesTo(&r, "9.9.9"));
}
