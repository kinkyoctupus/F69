// Application configuration. Loaded once at startup from
// `~/.config/f69/config.toml`, passed by const reference to services
// that need it.
//
// **Versioned.** First field is `version`. Loader rejects newer-than-
// binary configs (downgrade prevention) and migrates older ones forward
// (with original backed up to `config.toml.v<N>.bak`).
//
// Env vars override TOML values for select fields
// (F69_LIBRARY_ROOT, F69_F95_RATE_LIMIT_MS, ...).

const std = @import("std");

pub const CURRENT_VERSION: u32 = 1;

pub const AppConfig = struct {
    /// Schema version. Loader bumps this on migrate.
    version: u32 = CURRENT_VERSION,

    /// Where games install. Default: `$HOME/games/f69`.
    library_root: []const u8,
    /// Where downloads stage + caches live. Default: `$XDG_CACHE_HOME/f69`.
    cache_root: []const u8,
    /// Where user-authored recipes live. Default: `$XDG_CONFIG_HOME/f69/recipes`.
    recipe_local_dir: []const u8,
    /// Where the SQLite DB lives. Default: `$XDG_CONFIG_HOME/f69/games.db`.
    db_path: []const u8,

    /// Min ms between f95zone.to requests. Default: 1500.
    f95_rate_limit_ms: u64 = 1500,
    /// Default sandbox-on-launch; per-game override wins.
    sandbox_default: bool = true,
    /// 0 = never auto-prune old installs.
    prune_old_after_days: u32 = 0,
    /// If true, prefer `handlers/http.zig` over `handlers/aria2.zig` for plain HTTP.
    prefer_native_http: bool = false,

    /// Override paths to external tools. Empty = PATH lookup.
    aria2_path: []const u8 = "",
    /// Random per-app-startup secret for aria2 RPC; not persisted.
    aria2_rpc_secret: []const u8 = "",
    bwrap_path: []const u8 = "",
    /// Windows only.
    sandboxie_path: []const u8 = "",

    pub fn deinit(self: *AppConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.library_root);
        alloc.free(self.cache_root);
        alloc.free(self.recipe_local_dir);
        alloc.free(self.db_path);
        if (self.aria2_path.len > 0) alloc.free(self.aria2_path);
        if (self.aria2_rpc_secret.len > 0) alloc.free(self.aria2_rpc_secret);
        if (self.bwrap_path.len > 0) alloc.free(self.bwrap_path);
        if (self.sandboxie_path.len > 0) alloc.free(self.sandboxie_path);
        self.* = undefined;
    }
};

pub const Error = error{
    XdgPathUnavailable,
    InvalidConfigFile,
    /// Config from a future version of f69; refusing to downgrade.
    SchemaTooNew,
    /// Migration from older version to current failed.
    MigrationFailed,
    OutOfMemory,
};

/// Load config from disk (or defaults if file missing). Caller owns
/// the returned struct; call `.deinit(alloc)` to release.
///
/// Migration flow:
///   1. Parse TOML, read `version`.
///   2. If `version > CURRENT_VERSION` → return SchemaTooNew.
///   3. If `version < CURRENT_VERSION` → back up to
///      `<path>.v<version>.bak`, run migration chain, write back at
///      CURRENT_VERSION.
///   4. If file missing → write defaults at CURRENT_VERSION.
pub fn load(alloc: std.mem.Allocator) Error!AppConfig {
    _ = alloc;
    return Error.XdgPathUnavailable; // TODO
}
