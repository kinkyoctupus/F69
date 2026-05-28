// Error taxonomy for F95Indexer client calls.
//
// Mirrors the indexer's own error_flag values from
// `~/projects/F95Checker/indexer/f95zone.py:IndexerError`. The mapping
// happens server-side; we see only HTTP status + body. Network
// failures and JSON parse errors round out the surface so the refresh
// action can branch sanely.

pub const Error = error{
    /// DNS / TCP / TLS / timeout — indexer host unreachable.
    Unreachable,
    /// 400 Bad Request (`Max 10 IDs` / `IDs must be numeric` /
    /// `Invalid thread IDs` / `Invalid thread ID`). Always our bug.
    BadRequest,
    /// 404 from `/full/{id}` — thread doesn't exist on F95Zone.
    /// Caller can map this to `dev_status = .orphaned` same as scraper
    /// HTTP 404.
    ThreadMissing,
    /// 406 from `/full/{id}` — `ts > now()`. Always our bug (clock skew
    /// or programming error).
    BadTimestamp,
    /// 500 from `/full/{id}` with `INDEX_ERROR` flag — upstream F95Zone
    /// problem the indexer couldn't recover from. Retryable.
    SourceError,
    /// Body did not parse as expected JSON shape.
    ParseError,
    /// Caller passed more than MAX_IDS_PER_FAST ids to fastCheck.
    TooManyIds,
    OutOfMemory,
};
