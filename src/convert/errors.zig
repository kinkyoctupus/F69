pub const Error = error{
    UnknownEngine,
    EngineMismatch,
    VersionDetectFailed,
    SdkNotCached,
    SdkLayoutInvalid,
    SyslibResolveFailed,
    LauncherWriteFailed,
    LauncherNotFound,
    UnsupportedDistro,
    InstallNotFound,
    OutOfMemory,
    NetworkError,
    NotFound,
    NotImplemented,
    /// Convert-preset ZON failed to parse.
    ParseFailed,
    /// Failed to write a user preset file.
    WriteFailed,
};
