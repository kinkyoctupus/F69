// F95Zone scrape result types.

const std = @import("std");

pub const ScrapedThread = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    developer: ?[]const u8 = null,
    description_md: ?[]const u8 = null,
    /// Raw "changelog" / "updates" section pulled from the OP. Plain
    /// text — newlines preserved so it renders readably.
    changelog_md: ?[]const u8 = null,
    /// Quoted-reply blocks shown beneath the OP plus rated reviews from
    /// the review section. Flattened to a single string with `---` between
    /// entries; small enough to ship as one column.
    reviews_md: ?[]const u8 = null,
    /// "Downloads" section from the OP, structured with the same
    /// marker vocabulary as `changelog_md` (## headings, • bullets,
    /// [SPOILER=…][/SPOILER] foldouts, [LINK=URL]…[/LINK] inline
    /// hyperlinks). Renders verbatim in the Downloads tab.
    downloads_md: ?[]const u8 = null,
    cover_url: ?[]const u8 = null,
    rating: ?f32 = null,
    vote_count: ?u32 = null,
    /// Raw bracket token ("Ren'Py" / "RPGM MV"). Library maps via
    /// `Engine.fromBracket`; kept as string here so this module stays
    /// independent of the library Engine enum.
    engine_str: ?[]const u8 = null,
    /// Raw status token from the title ("Completed" / "Abandoned" /
    /// "On Hold" / "Ongoing"). Library maps via
    /// `DevStatus.fromBracket`.
    dev_status_str: ?[]const u8 = null,
    /// Unix seconds extracted from the OP's "Thread Updated:" /
    /// "Updated:" / "Game Updated:" line. Null when not present or
    /// not in a format we recognise.
    last_updated_at: ?i64 = null,
    /// Verbatim "Key: Value" lines pulled from the OP — Thread
    /// Updated, Release Date, Developer, Censored, Version, OS,
    /// Language, etc. The UI renders this as-is so the user sees the
    /// same format F95 publishes.
    thread_info_md: ?[]const u8 = null,
    /// Parsed "Censored:" value (no/yes/partial/unknown). Plumbed as
    /// `[]const u8` to keep this module free of the library enum;
    /// the worker resolves it via `library.CensoredState.fromText`.
    censored_str: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// Image URLs scraped from the OP body — feed the carousel.
    /// Capped at `thread.MAX_SCREENSHOTS` per game.
    screenshots: []const []const u8 = &.{},
    download_links: []const DownloadLink = &.{},
};

pub const DownloadHost = enum {
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

pub const DownloadLink = struct {
    host: DownloadHost,
    url: []const u8,
    label: ?[]const u8 = null,
    is_mod: bool = false,
};

pub const BookmarkEntry = struct {
    thread_id: []const u8,
    title: []const u8,
    url: []const u8,
};
