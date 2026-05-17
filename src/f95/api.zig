// F95Zone latest_alpha JSON API:
//   /sam/latest_alpha/latest_data.php?cmd=list&cat=games&page=N&rows=R&sort=date&date=D
// Used for batch update detection. Does NOT include rating/vote count.

const std = @import("std");
const errs = @import("errors.zig");
const domain = @import("domain.zig");
const Client = @import("client.zig").Client;

pub fn fetchUpdates(
    client: *Client,
    alloc: std.mem.Allocator,
    page: u32,
    rows: u32,
    days_back: u32,
) errs.Error![]domain.UpdateEntry {
    _ = client;
    _ = alloc;
    _ = page;
    _ = rows;
    _ = days_back;
    return &.{}; // TODO
}
