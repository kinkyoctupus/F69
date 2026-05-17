pub const Error = error{
    PlanInvalid,
    OverlayMountFailed,
    FileWriteFailed,
    UninstallFailed,
    DownloadFailed,
    HashMismatch,
    /// Recipe install step referenced a path that escapes the install
    /// dir (absolute path or `..` segment). Validator catches this at
    /// parse time; runtime is the defense-in-depth backstop.
    UnsafePath,
    OutOfMemory,
    /// Cooperative cancel: caller set the cancel flag on ApplyOpts and
    /// the apply loop unwound between files. Tracker reflects partial
    /// progress; caller is responsible for the rollback.
    Canceled,
};
