pub const Error = error{
    NetworkError,
    HttpStatusError,
    /// 5xx — server couldn't process; usually transient. Retry-worthy.
    ServerError,
    /// 401 / 403 — session cookie missing or expired.
    AuthRequired,
    /// 404 — endpoint or resource gone.
    NotFound,
    /// 429 — F95 said slow down.
    RateLimited,
    InvalidCookie,
    ParseError,
    OutOfMemory,
    /// Caller-requested cancel observed mid-flight. fetchAll's
    /// `Progress.cancel` atomic flips this in.
    Cancelled,
    /// `/sam/dddl.php` told us the F95 account isn't a donor (or
    /// donor status expired). Surface to the user so they understand
    /// "donor DDL" requires a paid F95 contribution.
    DonorNotEligible,
    /// `/sam/dddl.php` answered for the thread but reported no DDL
    /// is configured for it. Means this game doesn't ship via
    /// F95-hosted DDL; the user should fall back to RPDL/other.
    DonorNoDdl,
    /// Response shape from `/sam/dddl.php` didn't match
    /// `{"status":"ok"|"error","msg":…}` — the F95 endpoint shape
    /// changed and we can't trust the answer.
    DonorInvalidResponse,
};
