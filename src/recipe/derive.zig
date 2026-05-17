// Auto-derive a minimal game recipe from a scraped F95 thread page.
// Trimmed schema (post-2026-05-16): the recipe is just identity +
// sources (informational download links for sharing) + optional
// install steps. Convert spec, launch path, sandbox config, save
// paths — all moved out to engine handlers / per-game settings /
// global preferences.

const std = @import("std");
const errs = @import("errors.zig");
const dom = @import("domain.zig");

pub const ScrapeInput = struct {
    thread_id: u64,
    name: []const u8,
    version: []const u8,
    /// Discovered downloads from thread post body.
    download_links: []const struct {
        url: []const u8,
        host: dom.MirrorHost,
        label: ?[]const u8 = null,
    },
    /// Auto-detected if available; .unknown otherwise.
    engine: dom.Engine = .unknown,
    /// Kept for backward compat — callers may still pass a hint, but
    /// the field is no longer stored on the recipe.
    engine_version: ?[]const u8 = null,
};

/// Build a GameRecipe in-memory. All slices borrowed from `in` or
/// allocated through `alloc` — caller manages lifetime (typically via
/// arena passed in).
pub fn deriveGameRecipe(alloc: std.mem.Allocator, in: ScrapeInput) errs.Error!dom.GameRecipe {
    if (in.name.len == 0 or in.version.len == 0) return errs.Error.MissingRequiredField;
    _ = in.engine_version; // accepted as hint, not stored

    // Sources: every link becomes a `mirror` entry. Hash unknown until
    // user fills it in or the download verifies after first install.
    var sources: std.ArrayList(dom.Source) = .empty;
    errdefer sources.deinit(alloc);
    for (in.download_links) |link| {
        sources.append(alloc, .{ .mirror = .{
            .url = link.url,
            .host = link.host,
            .label = link.label,
            .sha256 = null,
        } }) catch return errs.Error.OutOfMemory;
    }

    // Default install: extract everything to install root, strip 1
    // (typical archive layout has a single top-level dir).
    var install: std.ArrayList(dom.InstallStep) = .empty;
    errdefer install.deinit(alloc);
    install.append(alloc, .{ .extract = .{ .to = ".", .strip = 1 } }) catch return errs.Error.OutOfMemory;

    return .{
        .id = in.name,
        .name = in.name,
        .f95_thread = in.thread_id,
        .version = in.version,
        .engine = in.engine,
        .sources = sources.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory,
        .install = install.toOwnedSlice(alloc) catch return errs.Error.OutOfMemory,
    };
}
