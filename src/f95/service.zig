// F95Service — public use cases. All hits to f95zone.to go through here
// so the rate limit is centrally enforced.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const Client = @import("client.zig").Client;
const thread = @import("thread.zig");
const api = @import("api.zig");
const bookmarks = @import("bookmarks.zig");
const auth = @import("auth.zig");
const indexer = @import("indexer.zig");

pub const Service = struct {
    alloc: std.mem.Allocator,
    client: *Client,

    pub fn init(alloc: std.mem.Allocator, client: *Client) Service {
        return .{ .alloc = alloc, .client = client };
    }

    pub fn scrapeThread(self: *Service, url: []const u8) errs.Error!domain.ScrapedThread {
        return thread.scrape(self.client, self.alloc, url);
    }

    pub fn fetchUpdates(self: *Service, page: u32, rows: u32, days_back: u32) errs.Error![]domain.UpdateEntry {
        return api.fetchUpdates(self.client, self.alloc, page, rows, days_back);
    }

    pub fn fetchBookmarks(self: *Service, progress: bookmarks.Progress) errs.Error![]domain.BookmarkEntry {
        return bookmarks.fetchAll(self.client, self.alloc, progress);
    }

    pub fn login(self: *Service, io: std.Io, creds: auth.Credentials) errs.Error![]u8 {
        // `auth.login` already calls `client.setCookie` on success.
        return auth.login(self.client, self.alloc, io, creds);
    }

    /// Fall back to the F95Indexer cache when direct scrape fails.
    pub fn scrapeViaIndexer(self: *Service, thread_id: []const u8) errs.Error!?domain.ScrapedThread {
        return indexer.fetchThread(self.alloc, thread_id);
    }
};
