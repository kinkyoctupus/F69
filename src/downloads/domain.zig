// Download job + progress types.

const std = @import("std");

pub const JobKind = enum { game, mod };
pub const JobStatus = enum {
    queued,
    fetching_metadata,
    downloading,
    verifying,
    extracting,
    applying,
    /// Torrent payload complete; still uploading toward seed-ratio
    /// target. Aria2 reports `status="active"` + `seeder=true` for this.
    seeding,
    /// User asked aria2 to pause this job (or pauseAll). Resume via
    /// the corresponding aria2 unpause RPC. Distinct from `.queued`
    /// (never started) and `.cancelled` (gone from aria2).
    paused,
    done,
    failed,
    cancelled,
};

pub const Job = struct {
    id: u64,
    kind: JobKind,
    /// F95 thread id of the game this job belongs to. 0 = unknown
    /// (e.g. user pasted a raw URL into the Downloads screen). The
    /// post-install hook uses this to pick the extract destination
    /// (`<library_root>/<game_id>/`).
    game_id: u64 = 0,
    mod_id: ?u64 = null,
    source_url: []const u8,
    expected_sha256: ?[32]u8 = null,
    /// Version of the game this archive contains, captured at enqueue
    /// time (from the RPDL torrent title, or the F95-scraped value
    /// for donor DDL). Owned by the Manager. `null` when we couldn't
    /// determine it; the post-install path then falls back to the
    /// recipe's version, or "unversioned" when there's no recipe.
    /// Persisted in `manager_jobs.json` so the version survives
    /// across restarts.
    version: ?[]const u8 = null,
    dest_path: []const u8,
    bytes_total: ?u64 = null,
    bytes_done: u64 = 0,
    /// Last-seen download throughput (bytes/sec). Refreshed by tick().
    download_speed: u64 = 0,
    /// Last-seen upload throughput (bytes/sec). Non-zero while seeding.
    upload_speed: u64 = 0,
    /// Cumulative uploaded byte count. Preserved by aria2 across
    /// restarts when --bt-save-metadata is on, so the seed-ratio
    /// progress bar stays meaningful between sessions.
    bytes_uploaded: u64 = 0,
    /// Live BT peer counts — 0 for plain HTTP jobs.
    num_seeders: u32 = 0,
    connections: u32 = 0,
    /// True iff aria2 reported this as a BitTorrent download.
    is_torrent: bool = false,
    status: JobStatus = .queued,
    /// Set by the Manager when this job is auto-paused because a
    /// higher-priority leeching download is in flight. Distinguishes
    /// "Manager paused this to free a slot" from "user clicked Pause".
    /// Cleared on auto-resume; user-pause leaves it false.
    priority_paused: bool = false,
    error_msg: ?[]const u8 = null,
};
