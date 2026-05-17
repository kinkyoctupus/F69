// Optional fallback to api.f95checker.dev (the F95Indexer cache). Used
// when a thread scrape fails or rate limit is in effect — the indexer
// caches f95zone thread data and re-serves it.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");

pub const BASE_URL = "https://api.f95checker.dev";

pub fn fetchThread(alloc: std.mem.Allocator, thread_id: []const u8) errs.Error!?domain.ScrapedThread {
    _ = alloc;
    _ = thread_id;
    return null; // TODO
}
