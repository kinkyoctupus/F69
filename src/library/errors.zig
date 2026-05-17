pub const Error = error{
    GameNotFound,
    InstallNotFound,
    ModNotFound,
    DuplicateGame,
    DuplicateInstall,
    InvalidVersion,
    SchemaMigrationFailed,
    SchemaTooNew,
    DatabaseError,
    OutOfMemory,
};
