// F95Service — public use cases. All hits to f95zone.to go through here
// so the rate limit is centrally enforced.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const Client = @import("client.zig").Client;
const thread = @import("thread.zig");
const bookmarks = @import("bookmarks.zig");
const auth = @import("auth.zig");

pub const Service = struct {
    alloc: std.mem.Allocator,
    client: *Client,

    pub fn init(alloc: std.mem.Allocator, client: *Client) Service {
        return .{ .alloc = alloc, .client = client };
    }

    pub fn scrapeThread(self: *Service, url: []const u8) errs.Error!domain.ScrapedThread {
        return thread.scrape(self.client, self.alloc, url);
    }

    pub fn fetchBookmarks(self: *Service, progress: bookmarks.Progress) errs.Error![]domain.BookmarkEntry {
        return bookmarks.fetchAll(self.client, self.alloc, progress);
    }

    pub fn login(self: *Service, io: std.Io, creds: auth.Credentials) errs.Error![]u8 {
        // `auth.login` already calls `client.setCookie` on success.
        return auth.login(self.client, self.alloc, io, creds);
    }
};
