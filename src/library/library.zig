// Library — zqlite-backed store for games, installs, mods, mod_installs.
// Single struct; no Service-over-Repo layer (architect review 2026-05-08).
// When real cross-context orchestration shows up, a Service in installer/
// is the right home for it, not here.
//
// Migrations are ordered SQL strings + a `_schema_version` table tracking
// each applied migration's id, hash, and timestamp. Hash check on startup
// catches accidental edits to applied SQL.
//
// Caller-owned strings: returned slices use the allocator passed into the
// call. Caller frees.

const std = @import("std");
const dbu = @import("util_db");
const dom = @import("domain.zig");
const errs = @import("errors.zig");
const version_mod = @import("util_version");

const log = std.log.scoped(.library);

pub const Game = dom.Game;
pub const Install = dom.Install;
pub const InstallSource = dom.InstallSource;
pub const AutoUpdateOverride = dom.AutoUpdateOverride;
pub const BackupModePref = dom.BackupModePref;
pub const Mod = dom.Mod;
pub const ModInstall = dom.ModInstall;
pub const CompletionStatus = dom.CompletionStatus;
pub const Engine = dom.Engine;
pub const DevStatus = dom.DevStatus;
pub const CensoredState = dom.CensoredState;
pub const SandboxOverride = dom.SandboxOverride;
pub const SavesPaths = dom.SavesPaths;
pub const errors = errs;

pub const Library = struct {
    alloc: std.mem.Allocator,
    conn: dbu.Conn,

    pub fn open(alloc: std.mem.Allocator, db_path: []const u8) errs.Error!Library {
        var conn = dbu.Conn.open(db_path, alloc, .{ .create = true }) catch return errs.Error.DatabaseError;
        errdefer conn.close();
        // SQLite defaults FK enforcement to OFF — turn it on so the
        // schema's `REFERENCES … ON DELETE CASCADE` clauses actually
        // fire. Per-connection setting, set once at open.
        conn.setPragmaInt(alloc, "foreign_keys", 1) catch return errs.Error.SchemaMigrationFailed;
        runMigrations(alloc, &conn) catch return errs.Error.SchemaMigrationFailed;
        return .{ .alloc = alloc, .conn = conn };
    }

    pub fn close(self: *Library) void {
        self.conn.close();
        self.* = undefined;
    }

    // ---- transactions ----
    //
    // SQLite default journal mode is rollback; nesting via savepoints
    // isn't exposed here. Caller must not nest beginTx calls.

    pub fn beginTx(self: *Library) errs.Error!void {
        self.conn.exec("BEGIN") catch return errs.Error.DatabaseError;
    }

    pub fn commitTx(self: *Library) errs.Error!void {
        self.conn.exec("COMMIT") catch return errs.Error.DatabaseError;
    }

    pub fn rollbackTx(self: *Library) errs.Error!void {
        self.conn.exec("ROLLBACK") catch return errs.Error.DatabaseError;
    }

    // -- games --

    /// JSON-encoded tags or "[]" if the game has none. Caller frees.
    fn encodeTagsJson(self: *Library, tags: []const []const u8) errs.Error![]u8 {
        return std.json.Stringify.valueAlloc(self.alloc, tags, .{}) catch return errs.Error.OutOfMemory;
    }

    /// INSERT OR IGNORE — used by the importer so re-pasting a thread
    /// list doesn't clobber rows that already have synced data.
    /// Returns true if a row was actually inserted.
    pub fn insertIfMissing(self: *Library, g: *const dom.Game) errs.Error!bool {
        const sql =
            \\INSERT OR IGNORE INTO games (
            \\  f95_thread_id, name, developer, cover_url, description_md,
            \\  tags_json, rating, vote_count, user_rating,
            \\  completion_status, engine, latest_version,
            \\  sandbox, last_played_at, total_playtime_s,
            \\  last_scraped_at, created_at, notes, screenshots_json,
            \\  changelog_md, reviews_md, download_links_json, dev_status,
            \\  downloads_md, last_updated_at, thread_info_md, censored
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;
        const tags_json = try self.encodeTagsJson(g.tags);
        defer self.alloc.free(tags_json);
        const screenshots_json = try self.encodeTagsJson(g.screenshots);
        defer self.alloc.free(screenshots_json);
        const dl_json = try self.encodeTagsJson(g.download_links);
        defer self.alloc.free(dl_json);
        self.conn.inner.exec(sql, .{
            @as(i64, @intCast(g.f95_thread_id)),
            g.name,
            g.developer,
            g.cover_url,
            g.description_md,
            tags_json,
            if (g.rating) |r| @as(?f64, @floatCast(r)) else null,
            if (g.vote_count) |v| @as(?i64, @intCast(v)) else null,
            if (g.user_rating) |r| @as(?f64, @floatCast(r)) else null,
            @tagName(g.completion_status),
            @tagName(g.engine),
            g.latest_version,
            @tagName(g.sandbox),
            g.last_played_at,
            @as(i64, @intCast(g.total_playtime_s)),
            g.last_scraped_at,
            g.created_at,
            g.notes,
            screenshots_json,
            g.changelog_md,
            g.reviews_md,
            dl_json,
            @tagName(g.dev_status),
            g.downloads_md,
            g.last_updated_at,
            g.thread_info_md,
            @tagName(g.censored),
        }) catch return errs.Error.DatabaseError;
        return self.conn.inner.changes() > 0;
    }

    /// INSERT OR REPLACE — upsert by f95_thread_id (primary key).
    pub fn upsertGame(self: *Library, g: *const dom.Game) errs.Error!void {
        const sql =
            \\INSERT OR REPLACE INTO games (
            \\  f95_thread_id, name, developer, cover_url, description_md,
            \\  tags_json, rating, vote_count, user_rating,
            \\  completion_status, engine, latest_version,
            \\  sandbox, last_played_at, total_playtime_s,
            \\  last_scraped_at, created_at, notes, screenshots_json,
            \\  changelog_md, reviews_md, download_links_json, dev_status,
            \\  downloads_md, last_updated_at, thread_info_md, censored,
            \\  auto_update, mod_backup_mode
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;
        const tags_json = try self.encodeTagsJson(g.tags);
        defer self.alloc.free(tags_json);
        const screenshots_json = try self.encodeTagsJson(g.screenshots);
        defer self.alloc.free(screenshots_json);
        const dl_json = try self.encodeTagsJson(g.download_links);
        defer self.alloc.free(dl_json);
        self.conn.inner.exec(sql, .{
            @as(i64, @intCast(g.f95_thread_id)),
            g.name,
            g.developer,
            g.cover_url,
            g.description_md,
            tags_json,
            // zqlite binds f64 from anytype; convert ?f32 → ?f64.
            if (g.rating) |r| @as(?f64, @floatCast(r)) else null,
            if (g.vote_count) |v| @as(?i64, @intCast(v)) else null,
            if (g.user_rating) |r| @as(?f64, @floatCast(r)) else null,
            @tagName(g.completion_status),
            @tagName(g.engine),
            g.latest_version,
            @tagName(g.sandbox),
            g.last_played_at,
            @as(i64, @intCast(g.total_playtime_s)),
            g.last_scraped_at,
            g.created_at,
            g.notes,
            screenshots_json,
            g.changelog_md,
            g.reviews_md,
            dl_json,
            @tagName(g.dev_status),
            g.downloads_md,
            g.last_updated_at,
            g.thread_info_md,
            @tagName(g.censored),
            @tagName(g.auto_update),
            @tagName(g.mod_backup_mode),
        }) catch return errs.Error.DatabaseError;
    }

    /// Single-column write — used by the Mods page dropdown so we
    /// don't have to re-`upsertGame` (which would clobber every
    /// other column the user might have edited concurrently).
    pub fn setGameModBackupMode(self: *Library, thread_id: u64, mode: dom.BackupModePref) errs.Error!void {
        self.conn.inner.exec(
            "UPDATE games SET mod_backup_mode = ? WHERE f95_thread_id = ?",
            .{ @tagName(mode), @as(i64, @intCast(thread_id)) },
        ) catch return errs.Error.DatabaseError;
    }

    pub fn getGame(self: *Library, thread_id: u64) errs.Error!?dom.Game {
        var rows = self.conn.inner.rows(
            \\SELECT f95_thread_id, name, developer, latest_version,
            \\       rating, vote_count, completion_status, engine,
            \\       sandbox, last_played_at, total_playtime_s, created_at,
            \\       notes, tags_json, last_scraped_at, screenshots_json,
            \\       description_md, changelog_md, reviews_md, download_links_json,
            \\       dev_status, downloads_md, last_updated_at, thread_info_md,
            \\       censored, auto_update, mod_backup_mode
            \\FROM games WHERE f95_thread_id = ?
        , .{@as(i64, @intCast(thread_id))}) catch return errs.Error.DatabaseError;
        defer rows.deinit();
        if (rows.next()) |r| {
            return try hydrateGame(self.alloc, r);
        }
        return null;
    }

    /// Returns a heap-allocated slice of Games. Caller frees via
    /// `freeGames(alloc, slice)` so all duplicated strings are released.
    pub fn listGames(self: *Library) errs.Error![]dom.Game {
        var out: std.ArrayList(dom.Game) = .empty;
        errdefer out.deinit(self.alloc);

        var rows = self.conn.inner.rows(
            \\SELECT f95_thread_id, name, developer, latest_version,
            \\       rating, vote_count, completion_status, engine,
            \\       sandbox, last_played_at, total_playtime_s, created_at,
            \\       notes, tags_json, last_scraped_at, screenshots_json,
            \\       description_md, changelog_md, reviews_md, download_links_json,
            \\       dev_status, downloads_md, last_updated_at, thread_info_md,
            \\       censored, auto_update, mod_backup_mode
            \\FROM games ORDER BY name COLLATE NOCASE
        , .{}) catch return errs.Error.DatabaseError;
        defer rows.deinit();

        while (rows.next()) |r| {
            const g = try hydrateGame(self.alloc, r);
            out.append(self.alloc, g) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory;
    }

    pub fn freeGames(self: *Library, games: []dom.Game) void {
        for (games) |g| {
            self.alloc.free(g.name);
            if (g.developer) |s| self.alloc.free(s);
            if (g.latest_version) |s| self.alloc.free(s);
            if (g.notes) |s| self.alloc.free(s);
            if (g.description_md) |s| self.alloc.free(s);
            if (g.changelog_md) |s| self.alloc.free(s);
            if (g.reviews_md) |s| self.alloc.free(s);
            if (g.downloads_md) |s| self.alloc.free(s);
            if (g.thread_info_md) |s| self.alloc.free(s);
            self.freeTags(g.tags);
            self.freeTags(g.screenshots);
            self.freeTags(g.download_links);
        }
        self.alloc.free(games);
    }

    fn freeTags(self: *Library, tags: []const []const u8) void {
        for (tags) |t| self.alloc.free(t);
        // Empty tag slices are conventionally `&.{}` (a comptime sentinel
        // with no heap backing), per `std.ArrayList.toOwnedSlice` and
        // `Allocator.alloc(T, 0)`. Skip free in that case to avoid
        // undefined behavior on the sentinel.
        if (tags.len > 0) self.alloc.free(tags);
    }

    pub fn deleteGame(self: *Library, thread_id: u64) errs.Error!void {
        self.conn.inner.exec("DELETE FROM games WHERE f95_thread_id = ?", .{@as(i64, @intCast(thread_id))}) catch return errs.Error.DatabaseError;
    }

    /// Apply scrape result to an in-memory `Game` whose strings are
    /// already owned by `self.alloc` (i.e. came out of `listGames`).
    /// Replaces name/developer/latest_version with fresh `self.alloc`-
    /// owned dups; updates rating/vote_count; persists.
    ///
    /// Borrowed inputs: `name`, `version`, `developer`, `cover_url` are
    /// caller-owned; we copy what we need.
    pub const ScrapeUpdate = struct {
        name: ?[]const u8 = null,
        version: ?[]const u8 = null,
        developer: ?[]const u8 = null,
        rating: ?f32 = null,
        vote_count: ?u32 = null,
        engine: ?dom.Engine = null,
        dev_status: ?dom.DevStatus = null,
        last_updated_at: ?i64 = null,
        thread_info_md: ?[]const u8 = null,
        censored: ?dom.CensoredState = null,
        /// When non-null, replaces the stored tag list wholesale.
        /// Empty slice clears tags. Caller-borrowed; we dupe.
        tags: ?[]const []const u8 = null,
        /// Same shape as `tags`: replace screenshot URL list wholesale.
        screenshots: ?[]const []const u8 = null,
        /// Plain-text scrape outputs. Empty string clears (stored NULL).
        description_md: ?[]const u8 = null,
        changelog_md: ?[]const u8 = null,
        reviews_md: ?[]const u8 = null,
        downloads_md: ?[]const u8 = null,
        /// Each entry pre-formatted as `<host>\t<url>\t<label>`. Empty
        /// slice clears.
        download_links: ?[]const []const u8 = null,
        /// Unix seconds — caller stamps via `Io.Clock.real`. Library
        /// stays clock-free.
        last_scraped_at: ?i64 = null,
    };

    pub fn applyScrape(self: *Library, game: *dom.Game, upd: ScrapeUpdate) errs.Error!void {
        if (upd.name) |new_name| {
            const dup = self.alloc.dupe(u8, new_name) catch return errs.Error.OutOfMemory;
            self.alloc.free(game.name);
            game.name = dup;
        }
        if (upd.version) |new_v| {
            const dup = self.alloc.dupe(u8, new_v) catch return errs.Error.OutOfMemory;
            if (game.latest_version) |old| self.alloc.free(old);
            game.latest_version = dup;
        }
        if (upd.developer) |new_d| {
            const dup = self.alloc.dupe(u8, new_d) catch return errs.Error.OutOfMemory;
            if (game.developer) |old| self.alloc.free(old);
            game.developer = dup;
        }
        if (upd.rating) |r| game.rating = r;
        if (upd.vote_count) |c| game.vote_count = c;
        if (upd.engine) |e| game.engine = e;
        if (upd.dev_status) |d| game.dev_status = d;
        if (upd.last_updated_at) |t| game.last_updated_at = t;
        if (upd.thread_info_md) |s| {
            try self.replaceOptionalString(&game.thread_info_md, s);
        }
        if (upd.censored) |c| game.censored = c;
        if (upd.last_scraped_at) |t| game.last_scraped_at = t;
        if (upd.tags) |new_tags| {
            game.tags = try self.dupStringList(new_tags, game.tags);
        }
        if (upd.screenshots) |new_shots| {
            game.screenshots = try self.dupStringList(new_shots, game.screenshots);
        }
        if (upd.description_md) |s| {
            try self.replaceOptionalString(&game.description_md, s);
        }
        if (upd.changelog_md) |s| {
            try self.replaceOptionalString(&game.changelog_md, s);
        }
        if (upd.reviews_md) |s| {
            try self.replaceOptionalString(&game.reviews_md, s);
        }
        if (upd.downloads_md) |s| {
            try self.replaceOptionalString(&game.downloads_md, s);
        }
        if (upd.download_links) |new_links| {
            game.download_links = try self.dupStringList(new_links, game.download_links);
        }
        try self.upsertGame(game);
    }

    /// Replace a `?[]const u8` field on a Game with a fresh
    /// `self.alloc`-owned copy of `src`. Empty `src` clears to null.
    fn replaceOptionalString(self: *Library, target: *?[]const u8, src: []const u8) errs.Error!void {
        if (src.len == 0) {
            if (target.*) |old| self.alloc.free(old);
            target.* = null;
            return;
        }
        const dup = self.alloc.dupe(u8, src) catch return errs.Error.OutOfMemory;
        if (target.*) |old| self.alloc.free(old);
        target.* = dup;
    }

    /// Helper: dup a slice-of-strings into `self.alloc`-owned storage,
    /// then free the previously-owned `old` slice. Allocates the new
    /// list before touching `old` so OOM doesn't leave the caller
    /// with a dangling field.
    fn dupStringList(
        self: *Library,
        src: []const []const u8,
        old: []const []const u8,
    ) errs.Error![]const []const u8 {
        const dup_outer = self.alloc.alloc([]const u8, src.len) catch return errs.Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (dup_outer[0..filled]) |t| self.alloc.free(t);
            self.alloc.free(dup_outer);
        }
        for (src) |t| {
            dup_outer[filled] = self.alloc.dupe(u8, t) catch return errs.Error.OutOfMemory;
            filled += 1;
        }
        self.freeTags(old);
        return dup_outer;
    }

    /// Replace `game.notes` with a `self.alloc`-owned copy of `text` and
    /// persist. Pass an empty slice to clear (stored as NULL in DB).
    pub fn setNotes(self: *Library, game: *dom.Game, text: []const u8) errs.Error!void {
        if (text.len == 0) {
            if (game.notes) |old| self.alloc.free(old);
            game.notes = null;
        } else {
            const dup = self.alloc.dupe(u8, text) catch return errs.Error.OutOfMemory;
            if (game.notes) |old| self.alloc.free(old);
            game.notes = dup;
        }
        try self.upsertGame(game);
    }

    pub fn ratingStats(self: *Library) errs.Error!struct { mean: f32, count: u32 } {
        var rows = self.conn.inner.rows(
            \\SELECT COALESCE(AVG(rating), 3.5), COUNT(rating)
            \\FROM games WHERE rating IS NOT NULL
        , .{}) catch return errs.Error.DatabaseError;
        defer rows.deinit();
        if (rows.next()) |r| {
            return .{
                .mean = @as(f32, @floatCast(r.float(0))),
                .count = @as(u32, @intCast(r.int(1))),
            };
        }
        return .{ .mean = 3.5, .count = 0 };
    }

    // -- installs --

    /// INSERT OR REPLACE the row. UUID-style id is generated by the
    /// caller (typically Round-35's post-download install hook). The
    /// schema's `UNIQUE(game_thread_id, version)` keeps duplicates out
    /// when the user re-installs the same version.
    pub fn upsertInstall(self: *Library, i: *const dom.Install) errs.Error!void {
        const id_slice = i.id[0..];
        const source_text: []const u8 = switch (i.source) {
            .recipe => "recipe",
            .manual => "manual",
            .rpdl => "rpdl",
            .imported => "imported",
        };
        const sha_slice: ?[]const u8 = if (i.archive_sha256) |*h| h[0..] else null;
        self.conn.inner.exec(
            \\INSERT OR REPLACE INTO installs
            \\  (id, game_thread_id, version, install_path, executable, launch_args,
            \\   recipe_id, installed_at, name, source, archive_sha256)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{
            id_slice,
            @as(i64, @intCast(i.game_thread_id)),
            i.version,
            i.install_path,
            i.executable orelse null,
            i.launch_args orelse null,
            i.recipe_id,
            i.installed_at,
            i.name orelse null,
            source_text,
            sha_slice,
        }) catch return errs.Error.DatabaseError;
    }

    /// Newest install first by VERSION (not `installed_at`). The
    /// picker dropdown shows them in this order and Launch always
    /// targets `installs[0]` — so the user gets a single rule:
    /// "the top of the dropdown is what runs." installed_at breaks
    /// ties when two installs share an equivalent version (e.g.
    /// vanilla v0.20 + modded v0.20 — the most recent one ranks
    /// first within the tie). Caller frees via `freeInstalls`.
    pub fn listInstalls(self: *Library, game_thread_id: u64) errs.Error![]dom.Install {
        var out: std.ArrayList(dom.Install) = .empty;
        errdefer out.deinit(self.alloc);

        // SQL fetch in any order — sort happens in Zig because
        // version strings need canonical parsing
        // (`util_version.compare`) that SQLite can't do.
        var rows = self.conn.inner.rows(
            \\SELECT id, game_thread_id, version, install_path,
            \\       executable, launch_args, recipe_id, installed_at,
            \\       name, source, archive_sha256
            \\FROM installs WHERE game_thread_id = ?
        , .{@as(i64, @intCast(game_thread_id))}) catch return errs.Error.DatabaseError;
        defer rows.deinit();

        while (rows.next()) |r| {
            const inst = try hydrateInstall(self.alloc, r);
            out.append(self.alloc, inst) catch return errs.Error.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.alloc) catch return errs.Error.OutOfMemory;
        std.mem.sort(dom.Install, slice, {}, installNewerFirst);
        return slice;
    }

    /// One SELECT DISTINCT over the installs table — returns every
    /// `game_thread_id` that has at least one install row. The UI
    /// builds an `AutoHashMap(u64, void)` from this once per frame to
    /// drive the "installed" badge on cards and the
    /// installed-state filter. Cheap query (the installs table is
    /// small + indexed).
    pub fn fetchInstalledThreadIds(self: *Library) errs.Error![]u64 {
        var out: std.ArrayList(u64) = .empty;
        errdefer out.deinit(self.alloc);

        var rows = self.conn.inner.rows(
            "SELECT DISTINCT game_thread_id FROM installs",
            .{},
        ) catch return errs.Error.DatabaseError;
        defer rows.deinit();
        while (rows.next()) |r| {
            const tid: i64 = r.int(0);
            out.append(self.alloc, @intCast(tid)) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    /// Highest-version install for a game (same ordering as
    /// `listInstalls`) or null when the table has no row for it.
    /// Used by the InstallDot heuristic and as the Launch fallback
    /// when the detail-page picker hasn't recorded a selection yet
    /// (e.g. card-click → Launch keybind before the detail page
    /// renders). Pays for one extra hydration pass vs the previous
    /// `LIMIT 1` query, but the installs table is small per-game.
    pub fn latestInstallForGame(self: *Library, game_thread_id: u64) errs.Error!?dom.Install {
        const installs = try self.listInstalls(game_thread_id);
        if (installs.len == 0) {
            self.alloc.free(installs);
            return null;
        }
        // Keep the head; free everything else.
        const head = installs[0];
        for (installs[1..]) |rest| self.freeInstall(rest);
        self.alloc.free(installs);
        return head;
    }

    /// Free strings in a single Install allocated via `listInstalls`
    /// or `latestInstallForGame`.
    pub fn freeInstall(self: *Library, i: dom.Install) void {
        self.alloc.free(i.version);
        self.alloc.free(i.install_path);
        if (i.executable) |s| self.alloc.free(s);
        if (i.launch_args) |s| self.alloc.free(s);
        self.alloc.free(i.recipe_id);
        if (i.name) |s| self.alloc.free(s);
    }

    pub fn freeInstalls(self: *Library, installs: []dom.Install) void {
        for (installs) |i| self.freeInstall(i);
        if (installs.len > 0) self.alloc.free(installs);
    }

    pub fn deleteInstall(self: *Library, install_id: []const u8) errs.Error!void {
        self.conn.inner.exec("DELETE FROM installs WHERE id = ?", .{install_id}) catch return errs.Error.DatabaseError;
    }

    /// Write a new `name` value on an existing install row. Pass null
    /// to clear the name (picker label falls back to bare version).
    /// Used by the detail-page ⋯ → Rename action.
    pub fn updateInstallName(self: *Library, install_id: []const u8, new_name: ?[]const u8) errs.Error!void {
        self.conn.inner.exec("UPDATE installs SET name = ? WHERE id = ?", .{
            new_name,
            install_id,
        }) catch return errs.Error.DatabaseError;
    }

    // -- mods --

    pub fn upsertMod(self: *Library, m: *const dom.Mod) errs.Error!void {
        _ = self;
        _ = m;
    }

    pub fn listMods(self: *Library, game_thread_id: u64) errs.Error![]dom.Mod {
        _ = self;
        _ = game_thread_id;
        return &.{};
    }

    // -- mod_installs (which mods are layered on which install) --

    pub fn setModInstalls(self: *Library, install_id: []const u8, items: []const dom.ModInstall) errs.Error!void {
        _ = self;
        _ = install_id;
        _ = items;
        // DELETE WHERE install_id=?, then bulk INSERT atomically.
    }

    pub fn listModInstalls(self: *Library, install_id: []const u8) errs.Error![]dom.ModInstall {
        _ = self;
        _ = install_id;
        return &.{};
    }

    // -- compat fixes applied to an install --
    //
    // Library stores raw rows; the compat service (which knows the
    // BackupRecord shape) converts to/from JSON. Keeping Library
    // compat-agnostic avoids a circular module dependency.

    pub const AppliedCompatRow = struct {
        recipe_id: []const u8,
        recipe_sha256: []const u8,
        applied_at: i64,
        /// JSON-serialized []BackupRecord. Owned by the same alloc
        /// passed to `listAppliedCompat`; freed via `freeAppliedCompat`.
        backups_json: []const u8,
    };

    pub fn upsertAppliedCompat(
        self: *Library,
        install_id: []const u8,
        recipe_id: []const u8,
        recipe_sha256: []const u8,
        applied_at: i64,
        backups_json: []const u8,
    ) errs.Error!void {
        self.conn.inner.exec(
            \\INSERT INTO applied_compat_fixes
            \\  (install_id, recipe_id, recipe_sha256, applied_at, backups_json)
            \\VALUES (?, ?, ?, ?, ?)
            \\ON CONFLICT(install_id, recipe_id) DO UPDATE SET
            \\  recipe_sha256 = excluded.recipe_sha256,
            \\  applied_at = excluded.applied_at,
            \\  backups_json = excluded.backups_json
        , .{
            install_id,
            recipe_id,
            recipe_sha256,
            applied_at,
            backups_json,
        }) catch return errs.Error.DatabaseError;
    }

    pub fn deleteAppliedCompat(self: *Library, install_id: []const u8, recipe_id: []const u8) errs.Error!void {
        self.conn.inner.exec(
            "DELETE FROM applied_compat_fixes WHERE install_id = ? AND recipe_id = ?",
            .{ install_id, recipe_id },
        ) catch return errs.Error.DatabaseError;
    }

    pub fn listAppliedCompat(self: *Library, install_id: []const u8) errs.Error![]AppliedCompatRow {
        var out: std.ArrayList(AppliedCompatRow) = .empty;
        errdefer {
            for (out.items) |row| self.freeAppliedCompatRow(row);
            out.deinit(self.alloc);
        }
        var rows = self.conn.inner.rows(
            \\SELECT recipe_id, recipe_sha256, applied_at, backups_json
            \\FROM applied_compat_fixes
            \\WHERE install_id = ?
            \\ORDER BY applied_at
        , .{install_id}) catch return errs.Error.DatabaseError;
        defer rows.deinit();
        while (rows.next()) |r| {
            const rid = self.alloc.dupe(u8, r.text(0)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(rid);
            const sha = self.alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(sha);
            const bjson = self.alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
            errdefer self.alloc.free(bjson);
            out.append(self.alloc, .{
                .recipe_id = rid,
                .recipe_sha256 = sha,
                .applied_at = r.int(2),
                .backups_json = bjson,
            }) catch return errs.Error.OutOfMemory;
        }
        return out.toOwnedSlice(self.alloc) catch errs.Error.OutOfMemory;
    }

    pub fn freeAppliedCompatRow(self: *Library, row: AppliedCompatRow) void {
        self.alloc.free(row.recipe_id);
        self.alloc.free(row.recipe_sha256);
        self.alloc.free(row.backups_json);
    }

    pub fn freeAppliedCompatList(self: *Library, list: []AppliedCompatRow) void {
        for (list) |row| self.freeAppliedCompatRow(row);
        if (list.len > 0) self.alloc.free(list);
    }
};

// ----- migrations -----

const Migration = struct {
    id: u32,
    sql: []const u8,
};

const migrations = [_]Migration{
    .{
        .id = 1,
        .sql =
        \\CREATE TABLE IF NOT EXISTS _schema_version (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS games (
        \\  f95_thread_id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  developer TEXT,
        \\  cover_url TEXT,
        \\  description_md TEXT,
        \\  tags_json TEXT NOT NULL DEFAULT '[]',
        \\  rating REAL,
        \\  vote_count INTEGER,
        \\  user_rating REAL,
        \\  completion_status TEXT NOT NULL DEFAULT 'not_started',
        \\  engine TEXT NOT NULL DEFAULT 'unknown',
        \\  latest_version TEXT,
        \\  default_install_id TEXT,
        \\  sandbox TEXT NOT NULL DEFAULT 'use_default',
        \\  last_played_at INTEGER,
        \\  total_playtime_s INTEGER NOT NULL DEFAULT 0,
        \\  last_scraped_at INTEGER,
        \\  created_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS installs (
        \\  id TEXT PRIMARY KEY,
        \\  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  version TEXT NOT NULL,
        \\  install_path TEXT NOT NULL UNIQUE,
        \\  executable TEXT,
        \\  launch_args TEXT,
        \\  recipe_id TEXT NOT NULL,
        \\  installed_at INTEGER NOT NULL,
        \\  UNIQUE (game_thread_id, version)
        \\);
        \\CREATE TABLE IF NOT EXISTS mods (
        \\  f95_thread_id INTEGER PRIMARY KEY,
        \\  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  name TEXT NOT NULL,
        \\  author TEXT,
        \\  latest_version TEXT,
        \\  created_at INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS mod_installs (
        \\  install_id TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
        \\  mod_thread_id INTEGER NOT NULL REFERENCES mods(f95_thread_id) ON DELETE CASCADE,
        \\  mod_version TEXT NOT NULL,
        \\  load_index INTEGER NOT NULL,
        \\  applied_at INTEGER NOT NULL,
        \\  PRIMARY KEY (install_id, mod_thread_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS games_name ON games(name COLLATE NOCASE);
        \\CREATE INDEX IF NOT EXISTS games_rating ON games(rating);
        \\CREATE INDEX IF NOT EXISTS installs_game ON installs(game_thread_id);
        \\CREATE INDEX IF NOT EXISTS mods_game ON mods(game_thread_id);
        \\CREATE INDEX IF NOT EXISTS mod_installs_install ON mod_installs(install_id);
        ,
    },
    .{
        .id = 2,
        .sql =
        \\ALTER TABLE games ADD COLUMN notes TEXT;
        ,
    },
    .{
        .id = 3,
        .sql =
        \\ALTER TABLE games ADD COLUMN screenshots_json TEXT;
        ,
    },
    .{
        .id = 4,
        .sql =
        \\ALTER TABLE games ADD COLUMN changelog_md TEXT;
        \\ALTER TABLE games ADD COLUMN reviews_md TEXT;
        \\ALTER TABLE games ADD COLUMN download_links_json TEXT;
        ,
    },
    .{
        .id = 5,
        .sql =
        \\ALTER TABLE games ADD COLUMN dev_status TEXT NOT NULL DEFAULT 'unknown';
        ,
    },
    .{
        .id = 6,
        .sql =
        \\ALTER TABLE games ADD COLUMN downloads_md TEXT;
        ,
    },
    .{
        .id = 7,
        .sql =
        \\ALTER TABLE games ADD COLUMN last_updated_at INTEGER;
        ,
    },
    .{
        .id = 8,
        .sql =
        \\ALTER TABLE games ADD COLUMN thread_info_md TEXT;
        ,
    },
    .{
        .id = 9,
        .sql =
        \\ALTER TABLE games ADD COLUMN censored TEXT NOT NULL DEFAULT 'unknown';
        ,
    },
    .{
        .id = 10,
        .sql =
        // Manual-install slice. Three changes in one migration:
        //   1. New columns: name (optional user label), source
        //      (recipe / manual / rpdl), archive_sha256 (hex hash
        //      of the source archive).
        //   2. Drop the UNIQUE(game_thread_id, version) constraint
        //      so a user can keep "0.20 modded" and "0.20 vanilla"
        //      side-by-side. install_path stays UNIQUE — that's
        //      the real on-disk identity.
        // SQLite has no ALTER ... DROP CONSTRAINT, so we recreate
        // the table. PRAGMA foreign_keys=OFF wraps the rebuild so
        // mod_installs' FK doesn't cascade rows away mid-rename.
        \\PRAGMA foreign_keys = OFF;
        \\CREATE TABLE installs_new (
        \\  id TEXT PRIMARY KEY,
        \\  game_thread_id INTEGER NOT NULL REFERENCES games(f95_thread_id) ON DELETE CASCADE,
        \\  version TEXT NOT NULL,
        \\  install_path TEXT NOT NULL UNIQUE,
        \\  executable TEXT,
        \\  launch_args TEXT,
        \\  recipe_id TEXT NOT NULL,
        \\  installed_at INTEGER NOT NULL,
        \\  name TEXT,
        \\  source TEXT NOT NULL DEFAULT 'recipe',
        \\  archive_sha256 TEXT
        \\);
        \\INSERT INTO installs_new
        \\  (id, game_thread_id, version, install_path, executable, launch_args,
        \\   recipe_id, installed_at)
        \\SELECT id, game_thread_id, version, install_path, executable, launch_args,
        \\       recipe_id, installed_at
        \\FROM installs;
        \\DROP TABLE installs;
        \\ALTER TABLE installs_new RENAME TO installs;
        \\CREATE INDEX IF NOT EXISTS installs_game ON installs(game_thread_id);
        \\PRAGMA foreign_keys = ON;
        ,
    },
    .{
        .id = 11,
        .sql =
        // Per-game auto-update override (always / never / use_default).
        // `use_default` defers to the global toggle in Settings.
        \\ALTER TABLE games ADD COLUMN auto_update TEXT NOT NULL DEFAULT 'use_default';
        ,
    },
    .{
        .id = 12,
        .sql =
        // Per-game uninstall safety: `none` (today's behaviour, no
        // pre-overwrite backups) or `copy` (mirror originals so
        // uninstall can restore). Picked via the Mods page dropdown.
        \\ALTER TABLE games ADD COLUMN mod_backup_mode TEXT NOT NULL DEFAULT 'none';
        ,
    },
    .{
        .id = 13,
        .sql =
        // Compat fixes applied to an install. One row per
        // (install_id, recipe_id). `recipe_sha256` lets the UI
        // detect "recipe upgraded since I applied it". `backups_json`
        // is the JSON-serialized []BackupRecord that `undo` needs.
        \\CREATE TABLE IF NOT EXISTS applied_compat_fixes (
        \\  install_id TEXT NOT NULL REFERENCES installs(id) ON DELETE CASCADE,
        \\  recipe_id TEXT NOT NULL,
        \\  recipe_sha256 TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL,
        \\  backups_json TEXT NOT NULL DEFAULT '[]',
        \\  PRIMARY KEY (install_id, recipe_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS applied_compat_install ON applied_compat_fixes(install_id);
        ,
    },
};

fn runMigrations(alloc: std.mem.Allocator, conn: *dbu.Conn) !void {
    // Make sure the version table exists. CREATE IF NOT EXISTS is idempotent.
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS _schema_version (
        \\  id INTEGER PRIMARY KEY,
        \\  hash TEXT NOT NULL,
        \\  applied_at INTEGER NOT NULL
        \\)
    );

    // Read max applied id.
    var max_applied: i64 = 0;
    {
        var rows = conn.inner.rows("SELECT COALESCE(MAX(id), 0) FROM _schema_version", .{}) catch return error.ExecFailed;
        defer rows.deinit();
        if (rows.next()) |r| max_applied = r.int(0);
    }

    // Refuse downgrade: if our highest declared id is below max applied,
    // the DB came from a newer build.
    var declared_max: u32 = 0;
    for (migrations) |m| {
        if (m.id > declared_max) declared_max = m.id;
    }
    if (max_applied > declared_max) {
        log.err("schema too new: db at {d}, binary supports up to {d}", .{ max_applied, declared_max });
        return error.SchemaTooNew;
    }

    // Apply pending migrations in order.
    var applied_now: u32 = 0;
    for (migrations) |m| {
        if (m.id <= max_applied) continue;

        // Hash for record (so accidental edits to applied SQL get caught
        // on the next start-up — `_schema_version.hash` is verified later
        // when we add a self-check pass).
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(m.sql, &sha, .{});
        const hex = std.fmt.bytesToHex(sha, .lower);

        try conn.execScript(alloc, m.sql);

        // Record the migration.
        const ins = std.fmt.allocPrint(
            alloc,
            "INSERT INTO _schema_version (id, hash, applied_at) VALUES ({d}, '{s}', {d})",
            .{ m.id, hex[0..], unixSecondsApprox() },
        ) catch return error.OutOfMemory;
        defer alloc.free(ins);
        try conn.exec(ins);

        applied_now += 1;
        log.info("migration {d} applied", .{m.id});
    }

    if (applied_now == 0) {
        log.info("no pending migrations (at {d})", .{max_applied});
    }
}

/// Coarse wall-clock seconds. Avoids std.time API churn between Zig
/// versions; we just want a stamp on rows.
fn unixSecondsApprox() i64 {
    return 0; // TODO: real clock; see std.Io.Clock in 0.16+.
}

/// Ordering used by `listInstalls` to sort newest-version-first.
/// Falls back to `installed_at DESC` when the canonical version
/// comparator can't distinguish (e.g. two installs of v0.20 with
/// different names). Returns `true` when `a` should sort BEFORE
/// `b` (per `std.mem.sort` contract — `lessThan`).
fn installNewerFirst(_: void, a: dom.Install, b: dom.Install) bool {
    return switch (version_mod.compare(a.version, b.version)) {
        .gt => true,
        .lt => false,
        .eq => a.installed_at > b.installed_at,
    };
}

/// Build a Game from a query row. Allocates copies of the text columns.
/// Numeric/enum columns are best-effort — unknown enum values fall back
/// to default variants.
fn hydrateInstall(alloc: std.mem.Allocator, r: anytype) errs.Error!dom.Install {
    var inst: dom.Install = .{
        .id = [_]u8{0} ** 36,
        .game_thread_id = 0,
        .version = "",
        .install_path = "",
        .recipe_id = "",
    };

    const id_text = r.text(0);
    const n = @min(id_text.len, inst.id.len);
    @memcpy(inst.id[0..n], id_text[0..n]);

    inst.game_thread_id = @as(u64, @intCast(r.int(1)));

    inst.version = alloc.dupe(u8, r.text(2)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(inst.version);

    inst.install_path = alloc.dupe(u8, r.text(3)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(inst.install_path);

    if (r.nullableText(4)) |s| {
        inst.executable = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (inst.executable) |s| alloc.free(s);

    if (r.nullableText(5)) |s| {
        inst.launch_args = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (inst.launch_args) |s| alloc.free(s);

    inst.recipe_id = alloc.dupe(u8, r.text(6)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(inst.recipe_id);

    inst.installed_at = r.int(7);

    // Columns 8..10 added in migration 10. Pre-migration rows return
    // null for `name` / `archive_sha256` and the schema default
    // `'recipe'` for `source`.
    if (r.nullableText(8)) |s| {
        inst.name = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (inst.name) |s| alloc.free(s);

    const src_text = r.text(9);
    inst.source = if (std.mem.eql(u8, src_text, "manual"))
        .manual
    else if (std.mem.eql(u8, src_text, "rpdl"))
        .rpdl
    else if (std.mem.eql(u8, src_text, "imported"))
        .imported
    else
        .recipe;

    if (r.nullableText(10)) |s| {
        if (s.len == 64) {
            var hex: [64]u8 = undefined;
            @memcpy(hex[0..], s);
            inst.archive_sha256 = hex;
        }
    }

    return inst;
}

fn hydrateGame(alloc: std.mem.Allocator, r: anytype) errs.Error!dom.Game {
    var g = dom.Game{
        .f95_thread_id = @as(u64, @intCast(r.int(0))),
        .name = "",
    };

    g.name = alloc.dupe(u8, r.text(1)) catch return errs.Error.OutOfMemory;
    errdefer alloc.free(g.name);

    if (r.nullableText(2)) |s| {
        g.developer = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (g.developer) |s| alloc.free(s);

    if (r.nullableText(3)) |s| {
        g.latest_version = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    errdefer if (g.latest_version) |s| alloc.free(s);

    if (r.nullableFloat(4)) |x| g.rating = @as(f32, @floatCast(x));
    if (r.nullableInt(5)) |x| g.vote_count = @as(u32, @intCast(x));

    g.completion_status = parseCompletion(r.text(6));
    g.engine = parseEngine(r.text(7));
    g.sandbox = parseSandbox(r.text(8));

    g.last_played_at = r.nullableInt(9);
    g.total_playtime_s = @as(u64, @intCast(r.int(10)));
    g.created_at = r.int(11);

    if (r.nullableText(12)) |s| {
        g.notes = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }

    // Tags are stored as a JSON array of strings.
    g.tags = decodeTagsJson(alloc, r.text(13)) catch &.{};

    g.last_scraped_at = r.nullableInt(14);

    // Screenshot URLs — stored as JSON array, same shape as tags.
    if (r.nullableText(15)) |s| {
        g.screenshots = decodeTagsJson(alloc, s) catch &.{};
    }

    // description / changelog / reviews — all nullable plain text.
    if (r.nullableText(16)) |s| {
        g.description_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    if (r.nullableText(17)) |s| {
        g.changelog_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    if (r.nullableText(18)) |s| {
        g.reviews_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    // Download-link list — same JSON-of-strings shape as tags.
    if (r.nullableText(19)) |s| {
        g.download_links = decodeTagsJson(alloc, s) catch &.{};
    }
    g.dev_status = dom.DevStatus.fromStr(r.text(20));
    if (r.nullableText(21)) |s| {
        g.downloads_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    g.last_updated_at = r.nullableInt(22);
    if (r.nullableText(23)) |s| {
        g.thread_info_md = alloc.dupe(u8, s) catch return errs.Error.OutOfMemory;
    }
    g.censored = dom.CensoredState.fromStr(r.text(24));
    g.auto_update = parseAutoUpdate(r.text(25));
    g.mod_backup_mode = parseBackupModePref(r.text(26));

    return g;
}

fn parseAutoUpdate(s: []const u8) dom.AutoUpdateOverride {
    if (std.mem.eql(u8, s, "always")) return .always;
    if (std.mem.eql(u8, s, "never")) return .never;
    return .use_default;
}

fn parseBackupModePref(s: []const u8) dom.BackupModePref {
    if (std.mem.eql(u8, s, "copy")) return .copy;
    return .none;
}

/// Parse a JSON array of strings into a freshly-`alloc`-owned slice
/// where every element is also `alloc`-owned. Returns empty on any
/// parse error so a corrupt row doesn't kill `listGames`; logs the
/// corruption so it surfaces in the log stream.
fn decodeTagsJson(alloc: std.mem.Allocator, json_text: []const u8) errs.Error![]const []const u8 {
    if (json_text.len == 0) return &.{};
    var parsed = std.json.parseFromSlice([]const []const u8, alloc, json_text, .{}) catch |err| {
        log.warn("tags_json corrupt — falling back to empty: {s}", .{@errorName(err)});
        return &.{};
    };
    defer parsed.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t);
        out.deinit(alloc);
    }
    for (parsed.value) |t| {
        const dup = alloc.dupe(u8, t) catch return errs.Error.OutOfMemory;
        errdefer alloc.free(dup);
        out.append(alloc, dup) catch return errs.Error.OutOfMemory;
    }
    return out.toOwnedSlice(alloc) catch errs.Error.OutOfMemory;
}

fn parseCompletion(s: []const u8) dom.CompletionStatus {
    if (std.mem.eql(u8, s, "in_queue")) return .in_queue;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, s, "completed")) return .completed;
    if (std.mem.eql(u8, s, "replaying")) return .replaying;
    if (std.mem.eql(u8, s, "abandoned")) return .abandoned;
    if (std.mem.eql(u8, s, "waiting_for_update")) return .waiting_for_update;
    return .not_started;
}

fn parseEngine(s: []const u8) dom.Engine {
    return dom.Engine.fromStr(s);
}

fn parseSandbox(s: []const u8) dom.SandboxOverride {
    if (std.mem.eql(u8, s, "always")) return .always;
    if (std.mem.eql(u8, s, "never")) return .never;
    return .use_default;
}

test "library: open + migrate + listGames empty" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    const games = try lib.listGames();
    defer lib.freeGames(games);
    try std.testing.expectEqual(@as(usize, 0), games.len);
}

test "library: install round-trip + latestInstallForGame" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 14014, .name = "Summertime Saga" });

    // Two installs at different times. Newest must come first.
    const id_a: [36]u8 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".*;
    const id_b: [36]u8 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb".*;
    try lib.upsertInstall(&.{
        .id = id_a,
        .game_thread_id = 14014,
        .version = "0.20.16",
        .install_path = "/games/14014/0.20.16",
        .recipe_id = "summertime-saga",
        .installed_at = 1_000,
    });
    try lib.upsertInstall(&.{
        .id = id_b,
        .game_thread_id = 14014,
        .version = "0.20.17",
        .install_path = "/games/14014/0.20.17",
        .recipe_id = "summertime-saga",
        .installed_at = 2_000,
    });

    const installs = try lib.listInstalls(14014);
    defer lib.freeInstalls(installs);
    try std.testing.expectEqual(@as(usize, 2), installs.len);
    try std.testing.expectEqualStrings("0.20.17", installs[0].version);
    try std.testing.expectEqualStrings("0.20.16", installs[1].version);

    const latest = (try lib.latestInstallForGame(14014)).?;
    defer lib.freeInstall(latest);
    try std.testing.expectEqualStrings("0.20.17", latest.version);
    try std.testing.expectEqualStrings("/games/14014/0.20.17", latest.install_path);
}

test "library: deleteInstall removes one row" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 14014, .name = "Summertime Saga" });
    const id: [36]u8 = "cccccccc-cccc-cccc-cccc-cccccccccccc".*;
    try lib.upsertInstall(&.{
        .id = id,
        .game_thread_id = 14014,
        .version = "1.0",
        .install_path = "/games/14014/1.0",
        .recipe_id = "x",
        .installed_at = 1,
    });

    try lib.deleteInstall(&id);
    const after = try lib.listInstalls(14014);
    defer lib.freeInstalls(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "library: deleteGame cascades to installs" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{ .f95_thread_id = 99, .name = "Doomed" });
    const id: [36]u8 = "dddddddd-dddd-dddd-dddd-dddddddddddd".*;
    try lib.upsertInstall(&.{
        .id = id,
        .game_thread_id = 99,
        .version = "1.0",
        .install_path = "/games/99/1.0",
        .recipe_id = "x",
        .installed_at = 1,
    });

    try lib.deleteGame(99);
    const orphans = try lib.listInstalls(99);
    defer lib.freeInstalls(orphans);
    try std.testing.expectEqual(@as(usize, 0), orphans.len);
}

test "library: upsert + list + getGame round-trip" {
    var lib = try Library.open(std.testing.allocator, ":memory:");
    defer lib.close();

    try lib.upsertGame(&.{
        .f95_thread_id = 12345,
        .name = "Summertime Saga",
        .developer = "Kompas Productions",
        .rating = 4.3,
        .vote_count = 9000,
        .latest_version = "0.20.17",
        .engine = .renpy,
        .completion_status = .in_progress,
        .sandbox = .always,
    });
    try lib.upsertGame(&.{
        .f95_thread_id = 67890,
        .name = "Babysitter",
        .rating = 3.8,
        .engine = .renpy,
    });

    const games = try lib.listGames();
    defer lib.freeGames(games);
    try std.testing.expectEqual(@as(usize, 2), games.len);
    // Ordered by name COLLATE NOCASE → Babysitter first.
    try std.testing.expectEqualStrings("Babysitter", games[0].name);
    try std.testing.expectEqualStrings("Summertime Saga", games[1].name);

    const stats = try lib.ratingStats();
    try std.testing.expectEqual(@as(u32, 2), stats.count);

    if (try lib.getGame(12345)) |g| {
        defer std.testing.allocator.free(g.name);
        defer if (g.developer) |s| std.testing.allocator.free(s);
        defer if (g.latest_version) |s| std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("Summertime Saga", g.name);
        try std.testing.expectEqual(dom.CompletionStatus.in_progress, g.completion_status);
        try std.testing.expectEqual(dom.SandboxOverride.always, g.sandbox);
    } else {
        return error.MissingGame;
    }
}

