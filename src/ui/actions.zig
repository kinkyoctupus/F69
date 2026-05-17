// Re-export wall for the per-domain action modules. After R9 the
// actual action implementations live under `src/ui/actions/`. This
// file exists so every existing `actions.X` call site (mostly in
// ui.zig + screens/* + main.zig) keeps resolving without churn.
//
// Layout map:
//   sync.zig         — syncGame, syncWorker, drainSync, sync recap,
//                      sync-all queue, advanceSyncQueue, image queue
//                      (phase-2 screenshots), slide/thumb/cover caches
//                      + prewarm. Owns SyncJob, SyncRecapEntry, ImageJob.
//   downloads.zig    — doDownloadGame + enqueueOneSource, RPDL worker
//                      (Tier 2), Donor DDL worker (Tier 1) + telemetry +
//                      retry, drainCompletedDownloads bridge. Owns
//                      RpdlDownloadJob, DonorDownloadJob.
//   installer.zig    — modJobRunner + runInstall/Uninstall, test-install
//                      preview, doInstallMod + conflicts + clash modal,
//                      resolver preflight, post-install pipeline,
//                      manual-install pipeline, install rename/delete.
//                      Owns TestInstallJob, PostInstallJob,
//                      ManualInstallJob[List], ModFileConflictAll,
//                      ClashModalState. Hosts postInstalledSet helper.
//   launch.zig       — doLaunchGame, doStopGame, isGameRunning,
//                      drainRunningGames, doConvertGame, compat env,
//                      shouldSandbox / shouldAutoUpdate /
//                      hasAutoFetchableSource / recipeReadyForAutoUpdate,
//                      lookupVersionFromArchiveSha,
//                      openManualInstallForUpdate, doBackupSaves,
//                      doOpenGameFolder, doOpenSaves, expandSavesPath.
//   bookmarks.zig    — doPullBookmarks, BookmarksJob worker,
//                      drainBookmarks, stripThreadPrefix +
//                      isLikelyNonGameTitle helpers (with tests).
//                      Owns BookmarksJob, BookmarksJobPhase.
//   auth.zig         — doLogin / doLogout / doRpdlLogin / doRpdlLogout.
//   mods.zig         — modfileForGame, refreshModfileCache,
//                      dropModfileCache, modsPageCache + lookups,
//                      isModInstalled, doUninstallMod, preset cache
//                      wiring, recipe wizard, mod-recipe delete,
//                      doScanModfiles, doDeleteModfile,
//                      simulateCurrentPlan, archive/install top-dirs,
//                      modTrackerLayout, openSettingsTab,
//                      resolveModsPageInstall / resolveConvertSpec /
//                      resolveGameRoot. Owns ModfileCache,
//                      ModsTabCounts, ModsPageCache, ModTrackerLayout.
//   tags.zig         — startRefreshTags, RefreshTagsJob worker,
//                      drainRefreshTags. Owns RefreshTagsJob.
//   imports.zig      — F95Checker / xLibrary importers, update-check
//                      job. Owns UpdateCheckJob.
//   common.zig       — bridge helpers (cancelAllWorkers, workersBusy,
//                      deleteGameAndReturn, installedSet/installDotState/
//                      retryDownload glue, attemptsMap, settings
//                      persistence, browser launch, friendlyError,
//                      persistTextFile, exeExistsUnder, freePostInstalled).

const sync = @import("actions/sync.zig");
const dl = @import("actions/downloads.zig");
const installer = @import("actions/installer.zig");
const launch = @import("actions/launch.zig");
const bookmarks = @import("actions/bookmarks.zig");
const auth = @import("actions/auth.zig");
const mods = @import("actions/mods.zig");
const tags = @import("actions/tags.zig");
const imports = @import("actions/imports.zig");
const common = @import("actions/common.zig");

// ---- Public type aliases (kept identical to pre-R9 names) ----
pub const SyncRecapEntry = sync.SyncRecapEntry;
pub const SyncJob = sync.SyncJob;
pub const ImageJob = sync.ImageJob;
pub const UpdateCheckJob = imports.UpdateCheckJob;
pub const RpdlDownloadJob = dl.RpdlDownloadJob;
pub const DonorDownloadJob = dl.DonorDownloadJob;
pub const RefreshTagsJob = tags.RefreshTagsJob;
pub const BookmarksJob = bookmarks.BookmarksJob;
pub const BookmarksJobPhase = bookmarks.BookmarksJobPhase;
pub const TestInstallJob = installer.TestInstallJob;
pub const PostInstallJob = installer.PostInstallJob;
pub const ManualInstallJob = installer.ManualInstallJob;
pub const ManualInstallJobsList = installer.ManualInstallJobsList;
pub const ModFileConflictAll = installer.ModFileConflictAll;
pub const ClashModalState = installer.ClashModalState;
pub const ModsTabCounts = mods.ModsTabCounts;
pub const ModsPageCache = mods.ModsPageCache;
pub const ModTrackerLayout = mods.ModTrackerLayout;
pub const InstallDotState = common.InstallDotState;
pub const DownloadedEntry = installer.DownloadedEntry;
pub const RunnerCtx = installer.RunnerCtx;
pub const ModFileConflict = installer.ModFileConflict;

// ---- Sync recap + sync engine ----
pub const syncRecapEntries = sync.syncRecapEntries;
pub const freeSyncRecap = sync.freeSyncRecap;
pub const clearSyncRecap = sync.clearSyncRecap;
pub const syncGame = sync.syncGame;
pub const screenshotPath = sync.screenshotPath;
pub const slideBytes = sync.slideBytes;
pub const freeSlideCache = sync.freeSlideCache;
pub const thumbBytes = sync.thumbBytes;
pub const freeThumbCache = sync.freeThumbCache;
pub const drainSync = sync.drainSync;
pub const startSyncAll = sync.startSyncAll;
pub const startSyncAllUnsynced = sync.startSyncAllUnsynced;
pub const queuePosition = sync.queuePosition;
pub const cancelSync = sync.cancelSync;
pub const cancelImageQueue = sync.cancelImageQueue;
pub const advanceSyncQueue = sync.advanceSyncQueue;
pub const enqueueImageFetch = sync.enqueueImageFetch;
pub const drainImageQueue = sync.drainImageQueue;
pub const coverPath = sync.coverPath;
pub const coverBytes = sync.coverBytes;
pub const coverFullBytes = sync.coverFullBytes;
pub const invalidateCover = sync.invalidateCover;
pub const freeCoverCache = sync.freeCoverCache;
pub const spawnCoverPrewarm = sync.spawnCoverPrewarm;

// ---- Update check + importers ----
pub const startUpdateCheck = imports.startUpdateCheck;
pub const drainUpdateCheck = imports.drainUpdateCheck;
pub const doImportFromF95Checker = imports.doImportFromF95Checker;
pub const doImportFromXLibrary = imports.doImportFromXLibrary;
pub const drainImport = imports.drainImport;

// ---- Common glue ----
pub const cancelAllWorkers = common.cancelAllWorkers;
pub const workersBusy = common.workersBusy;
pub const openInBrowser = common.openInBrowser;
pub const openExternalUrl = common.openExternalUrl;
pub const saveBrowserPath = common.saveBrowserPath;
pub const persistUiScaleIfDirty = common.persistUiScaleIfDirty;
pub const persistAutoCheckIfDirty = common.persistAutoCheckIfDirty;
pub const persistAutoConvertIfDirty = common.persistAutoConvertIfDirty;
pub const persistSandboxDefaultIfDirty = common.persistSandboxDefaultIfDirty;
pub const persistAutoUpdateDefaultIfDirty = common.persistAutoUpdateDefaultIfDirty;
pub const saveAria2Port = common.saveAria2Port;
pub const saveAria2SeedRatio = common.saveAria2SeedRatio;
pub const maybeAutoUpdateCheck = common.maybeAutoUpdateCheck;
pub const deleteGameAndReturn = common.deleteGameAndReturn;
pub const refreshInstalledSet = common.refreshInstalledSet;
pub const isInstalled = common.isInstalled;
pub const retryDownload = common.retryDownload;
pub const installDotState = common.installDotState;
pub const freeInstalledSet = common.freeInstalledSet;
pub const freePostInstalled = common.freePostInstalled;

// ---- Downloads ----
pub const startRpdlDownload = dl.startRpdlDownload;
pub const drainRpdlDownload = dl.drainRpdlDownload;
pub const freeDonorTables = dl.freeDonorTables;
pub const drainDonorTelemetry = dl.drainDonorTelemetry;
pub const isDonorJob = dl.isDonorJob;
pub const startDonorDownload = dl.startDonorDownload;
pub const drainDonorDownload = dl.drainDonorDownload;
pub const maybeRetryDonorJob = dl.maybeRetryDonorJob;
pub const hasActiveDownloadForGame = dl.hasActiveDownloadForGame;
pub const findLeechingJobForGame = dl.findLeechingJobForGame;
pub const doDownloadGame = dl.doDownloadGame;
pub const drainCompletedDownloads = dl.drainCompletedDownloads;

// ---- Refresh tags ----
pub const startRefreshTags = tags.startRefreshTags;
pub const drainRefreshTags = tags.drainRefreshTags;
pub const freeTagsMaster = tags.freeTagsMaster;

// ---- Bookmarks ----
pub const cancelBookmarks = bookmarks.cancelBookmarks;
pub const startPullBookmarks = bookmarks.startPullBookmarks;
pub const drainBookmarks = bookmarks.drainBookmarks;

// ---- Auth ----
pub const doLogin = auth.doLogin;
pub const doLogout = auth.doLogout;
pub const doRpdlLogin = auth.doRpdlLogin;
pub const doRpdlLogout = auth.doRpdlLogout;

// ---- Launch / convert / running games / saves ----
pub const doLaunchGame = launch.doLaunchGame;
pub const scanCompatForInstall = launch.scanCompatForInstall;
pub const freeCompatIssues = launch.freeCompatIssues;
pub const applyCompatFix = launch.applyCompatFix;
pub const undoCompatFix = launch.undoCompatFix;
pub const shouldSandbox = launch.shouldSandbox;
pub const shouldAutoUpdate = launch.shouldAutoUpdate;
pub const hasAutoFetchableSource = launch.hasAutoFetchableSource;
pub const recipeReadyForAutoUpdate = launch.recipeReadyForAutoUpdate;
pub const lookupVersionFromArchiveSha = launch.lookupVersionFromArchiveSha;
pub const openManualInstallForUpdate = launch.openManualInstallForUpdate;
pub const doConvertGame = launch.doConvertGame;
pub const isGameRunning = launch.isGameRunning;
pub const doStopGame = launch.doStopGame;
pub const drainRunningGames = launch.drainRunningGames;
pub const doBackupSaves = launch.doBackupSaves;
pub const doOpenGameFolder = launch.doOpenGameFolder;
pub const doOpenSaves = launch.doOpenSaves;
pub const expandSavesPath = launch.expandSavesPath;

// ---- Installer (mod-job runner + post-install + manual install) ----
pub const isModInstalled = mods.isModInstalled;
pub const doUninstallMod = installer.doUninstallMod;
pub const modJobRunner = installer.modJobRunner;
pub const recoverModJobsFromDisk = installer.recoverModJobsFromDisk;
pub const drainModJobs = installer.drainModJobs;
pub const doInstallMod = installer.doInstallMod;
pub const clashModalState = installer.clashModalState;
pub const closeClashModal = installer.closeClashModal;
pub const freeClashModalState = installer.freeClashModalState;
pub const clashModalAcceptAll = installer.clashModalAcceptAll;
pub const detectModFileConflicts = installer.detectModFileConflicts;
pub const doTestInstallPreview = installer.doTestInstallPreview;
pub const drainTestInstall = installer.drainTestInstall;
pub const isTestInstallRunning = installer.isTestInstallRunning;
pub const freeTestInstallJob = installer.freeTestInstallJob;
pub const freePostInstallJobs = installer.freePostInstallJobs;
pub const isExtracting = installer.isExtracting;
pub const hasDownloadedButNotInstalled = installer.hasDownloadedButNotInstalled;
pub const listDownloadedNotInstalled = installer.listDownloadedNotInstalled;
pub const startInstallFromDownloadJob = installer.startInstallFromDownloadJob;
pub const startInstallFromDownload = installer.startInstallFromDownload;
pub const isInstallingForGame = installer.isInstallingForGame;
pub const extractProgressForGame = installer.extractProgressForGame;
pub const anyPostInstallActive = installer.anyPostInstallActive;
pub const drainPostInstall = installer.drainPostInstall;
pub const freeManualInstallJobs = installer.freeManualInstallJobs;
pub const manualInstallsRunning = installer.manualInstallsRunning;
pub const startManualInstall = installer.startManualInstall;
pub const drainManualInstall = installer.drainManualInstall;
pub const doRenameInstall = installer.doRenameInstall;
pub const doDeleteInstall = installer.doDeleteInstall;

// ---- Mods page ----
pub const doRegisterModArchive = mods.doRegisterModArchive;
pub const findRegisteredModArchive = mods.findRegisteredModArchive;
pub const dropModfileCache = mods.dropModfileCache;
pub const freeModfileCacheState = mods.freeModfileCacheState;
pub const dropModsPageCache = mods.dropModsPageCache;
pub const freeModsPageCacheState = mods.freeModsPageCacheState;
pub const modsPageCache = mods.modsPageCache;
pub const refreshModfileCache = mods.refreshModfileCache;
pub const modfilesForGame = mods.modfilesForGame;
pub const doAddModfile = mods.doAddModfile;
pub const doImportModRecipe = mods.doImportModRecipe;
pub const resolveModsPageInstall = mods.resolveModsPageInstall;
pub const resolveConvertSpec = mods.resolveConvertSpec;
pub const resolveGameRoot = mods.resolveGameRoot;
pub const modTrackerLayout = mods.modTrackerLayout;
pub const freeModTrackerLayout = mods.freeModTrackerLayout;
pub const modfileArchivePath = mods.modfileArchivePath;
pub const archiveTopDirs = mods.archiveTopDirs;
pub const freeTopDirs = mods.freeTopDirs;
pub const installTopDirs = mods.installTopDirs;
pub const simulateCurrentPlan = mods.simulateCurrentPlan;
pub const doDeleteUserPresetArmed = mods.doDeleteUserPresetArmed;
pub const getMergedPresets = mods.getMergedPresets;
pub const invalidatePresetCache = mods.invalidatePresetCache;
pub const doSetModfilePreset = mods.doSetModfilePreset;
pub const doSaveModRecipeAsPreset = mods.doSaveModRecipeAsPreset;
pub const openSettingsTab = mods.openSettingsTab;
pub const doScanModfiles = mods.doScanModfiles;
pub const doDeleteModfile = mods.doDeleteModfile;
pub const clearPendingDelete = mods.clearPendingDelete;
pub const doDeleteModRecipe = mods.doDeleteModRecipe;
pub const doDeleteModRecipeArmed = mods.doDeleteModRecipeArmed;
pub const openWizardForModfile = mods.openWizardForModfile;
pub const closeWizard = mods.closeWizard;
pub const wizardAddBlock = mods.wizardAddBlock;
pub const wizardRemoveBlock = mods.wizardRemoveBlock;
pub const wizardSave = mods.wizardSave;
