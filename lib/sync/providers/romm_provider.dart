/// RomM save-sync provider.
///
/// Syncs emulator save files and save states between the local device and a
/// self-hosted RomM instance, mirroring NeoSync's per-game flow (download newer
/// remote saves before launch, upload changed local saves after the game
/// closes).
///
/// It reuses the existing, already-authenticated [RommProvider] (library browse)
/// connection — no second login — and delegates local save-file *location* to
/// [NeoSyncProvider]'s battle-tested path resolution. Sync state is tracked in
/// the shared, provider-agnostic `app_neo_sync_state` table via [SyncRepository].
///
/// Saves are keyed by RomM `rom_id`, which is only known for games downloaded
/// from RomM (recorded in `app_romm_rom_map` at download time). Games with no
/// mapping are treated as not-linked and skipped.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/services/retroarch_config_service.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_playtime_service.dart';
import 'package:neostation/services/romm_service.dart';

import '../i_sync_provider.dart';

/// Locates the local save/state files belonging to a game.
typedef LocateGameSaves = Future<List<LocalSaveFile>> Function(GameModel game);

/// Resolves the candidate local destination paths for a cloud file named
/// [relativeName] (e.g. `saves/Game.srm`) belonging to a game.
typedef ResolveSaveTargets =
    Future<List<String>> Function(GameModel game, String relativeName);

class RomMSyncProvider extends ChangeNotifier implements ISyncProvider {
  static const String kProviderId = 'romm';

  /// Tolerance (ms) for local-vs-recorded mtime comparisons, matching NeoSync.
  static const int _mtimeToleranceMs = 2000;

  /// Label stamped onto RomM's `emulator` field for assets we create.
  ///
  /// Deliberately a *constant*, not the save's per-core subfolder. RomM uses
  /// this value as a directory component when it stores the file, so encoding
  /// something device-specific in it gives two devices two different storage
  /// paths for one logical save — and because RomM matches assets on
  /// `(rom_id, file_name)` alone, they then fight over a single row that only
  /// ever serves whichever device created it. A device-independent label keeps
  /// every device on one path, which is what lets a save actually round-trip.
  ///
  /// Where the file belongs *locally* is a local question, answered on download
  /// from this device's own RetroArch configuration — see [_localSubfolder].
  static const String _assetLabel = 'neostation';

  static final _log = LoggerService.instance;

  /// Authenticated RomM connection, shared with the library browser.
  final RommProvider _browse;

  /// Used only to locate/place local save files (path resolution reuse).
  final NeoSyncProvider _neoSync;

  /// Test seams for NeoSync's path resolution. [NeoSyncProvider]'s
  /// `locateGameSaveFiles`/`resolveLocalTargetPaths` live in an `extension`
  /// (static dispatch), so they can't be faked by subclassing — tests inject
  /// replacements here instead, mirroring [RommBulkSync.run]'s callbacks.
  final LocateGameSaves? _locateOverride;
  final ResolveSaveTargets? _resolveTargetsOverride;

  final Map<String, GameSyncState> _gameSyncStates = {};

  RomMSyncProvider(
    this._browse,
    this._neoSync, {
    @visibleForTesting LocateGameSaves? locateSaves,
    @visibleForTesting ResolveSaveTargets? resolveTargets,
  }) : _locateOverride = locateSaves,
       _resolveTargetsOverride = resolveTargets;

  Future<List<LocalSaveFile>> _locateSaves(GameModel game) =>
      (_locateOverride ?? _neoSync.locateGameSaveFiles)(game);

  Future<List<String>> _resolveTargets(GameModel game, String relativeName) =>
      (_resolveTargetsOverride ?? _neoSync.resolveLocalTargetPaths)(
        game,
        relativeName,
      );

  RommService get _svc => _browse.service;

  // ── Identity ───────────────────────────────────────────────────────────────

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => const SyncProviderMeta(
    id: kProviderId,
    name: 'RomM',
    description:
        'Self-hosted sync via your own RomM instance. Uses your RomM '
        'connection — only games downloaded from RomM are synced.',
    author: 'Community',
    iconAssetPath: 'assets/icons/romm.png',
  );

  // ── State ──────────────────────────────────────────────────────────────────

  @override
  SyncProviderStatus get status {
    switch (_browse.status) {
      case RommConnectionStatus.connected:
        return SyncProviderStatus.connected;
      case RommConnectionStatus.connecting:
        return SyncProviderStatus.connecting;
      case RommConnectionStatus.error:
        return SyncProviderStatus.error;
      case RommConnectionStatus.disconnected:
        return SyncProviderStatus.disconnected;
    }
  }

  @override
  bool get isAuthenticated => _browse.isConnected;

  @override
  String? get lastError => _browse.lastError;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    // The browse RommProvider restores config + tokens in its own initialize().
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  @override
  Future<SyncResult> login() async {
    if (_browse.isConnected) return SyncResult.ok();
    return SyncResult.fail(
      SyncError.authRequired,
      message: 'Connect to RomM in Settings → RomM first',
    );
  }

  @override
  Future<void> logout() async {
    await _browse.disconnect();
  }

  // ── Mapping / discovery helpers ─────────────────────────────────────────────

  /// Resolves the RomM `rom_id` for [game], or null if the game isn't linked
  /// to a RomM ROM (i.e. wasn't downloaded from RomM).
  Future<int?> _resolveRomId(GameModel game) async {
    final systemFolder = game.systemFolderName;
    if (systemFolder == null || systemFolder.isEmpty) return null;
    return RommSaveMapRepository.getRommRomId(game.romname, systemFolder);
  }

  GameSyncState _buildState(
    GameModel game,
    GameSyncStatus status, {
    String? errorMessage,
  }) => GameSyncState(
    gameId: game.romname,
    gameName: game.name,
    status: status,
    // Null counts as disabled, matching the [_syncGame] gate and NeoSync.
    cloudEnabled: game.cloudSyncEnabled == true,
    errorMessage: errorMessage,
  );

  // ── Core per-game sync ──────────────────────────────────────────────────────

  /// Bidirectional sync for [game]. When [downloadOnly] is true (pre-launch),
  /// only newer/missing remote files are pulled; otherwise local changes are
  /// also pushed.
  Future<GameSyncStatus> _syncGame(
    GameModel game, {
    required bool downloadOnly,
    SyncDeadline? deadline,
  }) async {
    if (!_browse.isConnected) return GameSyncStatus.error;
    // Honour the sync opt-outs exactly the way NeoSync does: a null per-game
    // flag counts as disabled, and a system whose config sets `sync: false`
    // (e.g. shared-memcard systems the user deliberately excluded) is skipped
    // regardless of the per-game flag.
    if (game.cloudSyncEnabled != true) return GameSyncStatus.disabled;
    final systemFolder = game.systemFolderName;
    if (systemFolder != null && systemFolder.isNotEmpty) {
      final system = await SystemRepository.getSystemByFolderName(systemFolder);
      if (system != null && !system.neosync.sync) {
        return GameSyncStatus.disabled;
      }
    }

    final romId = await _resolveRomId(game);
    if (romId == null) {
      // Not a RomM-linked game (wasn't downloaded through the app). Report
      // "disabled" — sync simply doesn't apply — rather than "no save found",
      // which would be a lie whenever the game has perfectly good local saves.
      return GameSyncStatus.disabled;
    }

    final localFiles = syncableSaves(game, await _locateSaves(game));

    final List<RommAsset> remote;
    try {
      // The two listings are independent GETs; fetch them concurrently so the
      // launch-blocking sync pays one round-trip, not two serial ones.
      final results = await Future.wait([
        _svc.listSaves(romId: romId),
        _svc.listStates(romId: romId),
      ]);
      remote = [...results[0], ...results[1]];
    } catch (e) {
      _log.e('RomM listSaves/listStates failed for ${game.romname}: $e');
      return GameSyncStatus.error;
    }

    final matchedRemote = <int>{}; // asset ids already paired with a local file
    int uploaded = 0, downloaded = 0;
    bool anyLocal = localFiles.isNotEmpty;
    bool anyRemote = remote.isNotEmpty;

    // 1) Reconcile each local file against its remote counterpart.
    for (final local in localFiles) {
      final isState = local.relativePath.startsWith('states/');
      final baseName = path.basename(local.filePath);
      RommAsset? match;
      for (final a in remote) {
        if (a.isState == isState && a.fileName == baseName) {
          match = a;
          break;
        }
      }
      if (match != null) matchedRemote.add(match.id);

      final localMs = local.lastModified.millisecondsSinceEpoch;
      final recorded = await SyncRepository.getSyncState(
        kProviderId,
        local.filePath,
      );
      final recordedLocalMs = (recorded?['local_modified_at'] as int?) ?? 0;
      final recordedCloudMs = (recorded?['cloud_updated_at'] as int?) ?? 0;

      final localChanged =
          recorded == null || localMs > recordedLocalMs + _mtimeToleranceMs;

      if (match == null) {
        // Local only → upload (unless pre-launch download-only pass).
        if (!downloadOnly) {
          if (await _upload(romId, local, isState)) uploaded++;
        }
        continue;
      }

      final remoteChanged = match.updatedAtMs > recordedCloudMs;

      if (remoteChanged && !localChanged) {
        // Remote is newer and local is untouched → safe to pull. A locally
        // changed save is never overwritten here, even in a download-only
        // (pre-launch) pass — its upload is simply deferred to the next
        // upload-capable sync, so un-synced local progress is never lost.
        if (await _download(
          game,
          match,
          localFiles: localFiles,
          deadline: deadline,
        )) {
          downloaded++;
        }
      } else if (localChanged && !downloadOnly) {
        // Local newer (or both changed → prefer local). The asset exists, so
        // this replaces it in place rather than creating a second one.
        if (await _upload(romId, local, isState, existing: match)) uploaded++;
      }
    }

    // 2) Remote-only files → download.
    for (final a in remote) {
      if (matchedRemote.contains(a.id)) continue;
      if (await _download(
        game,
        a,
        localFiles: localFiles,
        deadline: deadline,
      )) {
        downloaded++;
      }
    }

    _log.i(
      'RomM sync ${game.romname}: $uploaded up, $downloaded down '
      '(${localFiles.length} local, ${remote.length} remote)',
    );

    // Playtime rides along with the upload-capable passes only. The pre-launch
    // pass is on the launch's critical path and playtime changes nothing about
    // the game that's about to start, so it stays out of that budget.
    if (!downloadOnly) {
      await _syncPlaytime(game, romId);
    }

    if (!anyLocal && !anyRemote) return GameSyncStatus.noSaveFound;
    if (!anyRemote) return GameSyncStatus.localOnly;
    if (!anyLocal && downloaded == 0) return GameSyncStatus.cloudOnly;
    return GameSyncStatus.upToDate;
  }

  /// Pushes queued play sessions and pulls back playtime recorded elsewhere.
  ///
  /// Best-effort by design: playtime is a statistic, so a failure here must
  /// never change the save-sync status the user is shown, and never throw into
  /// the launch/close flow. [RommPlaytimeService] throttles the pull itself, so
  /// this is cheap to call from the per-selection save detection.
  Future<void> _syncPlaytime(GameModel game, int romId) async {
    if (!_svc.playtimeSyncAvailable) return;
    try {
      await RommPlaytimeService.flushQueuedSessions(_svc);
      final romPath = game.romPath;
      if (romPath != null && romPath.isNotEmpty) {
        await RommPlaytimeService.pullPlaytime(
          _svc,
          romId: romId,
          romPath: romPath,
        );
      }
    } catch (e) {
      _log.w('RomM playtime sync failed for ${game.romname}: $e');
    }
  }

  /// Extracts the save-folder subpath (e.g. RetroArch's per-core `FCEUmm`
  /// folder) from a local file's `saves/…`/`states/…` relative path, so it can
  /// be preserved across the round-trip via RomM's `emulator` field. Returns
  /// empty when the file sits directly in the saves/states root.
  /// Extensions RetroArch writes *beside* a save state as its thumbnail. These
  /// are screenshots, not save data — RetroArch regenerates them, and RomM has
  /// a dedicated `screenshotFile` field for the one place a thumbnail belongs.
  static const Set<String> _thumbnailExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.bmp',
  };

  /// Narrows the locator's results to files that are really [game]'s save data.
  ///
  /// NeoSync's locator matches any file whose name *contains* the game name and
  /// applies no extension filter at all. That looseness is load-bearing for the
  /// cases it was built for — shared PS2/Dreamcast memory cards and Switch
  /// saves matched by title id, neither of which carries the game's name in the
  /// filename — so it is left alone and tightened here, at RomM's door.
  ///
  /// Two things get dropped:
  ///
  /// * **Thumbnails.** A `.state.png` was being uploaded to RomM as a save
  ///   state. Confirmed on device: one play session produced four "states",
  ///   two of which were screenshots.
  /// * **A longer-named game's saves.** `contains` makes the match one-way:
  ///   a game called `Extra Mario Bros.` matches `Extra Mario Bros. [Hacks].state`,
  ///   so the shorter title would sync the longer one's saves as its own. A
  ///   file is rejected only when it can be *proved* to belong elsewhere —
  ///   its name starts with this game's name but continues with something
  ///   other than an extension. Files that don't start with the game's name at
  ///   all are left untouched, which is what keeps the memory-card and Switch
  ///   paths working.
  @visibleForTesting
  static List<LocalSaveFile> syncableSaves(
    GameModel game,
    List<LocalSaveFile> found,
  ) {
    final romName = _romNameWithoutExtension(game.romname).toLowerCase();

    return found.where((f) {
      final name = path.basename(f.filePath);
      final lower = name.toLowerCase();

      if (_thumbnailExtensions.contains(path.extension(lower))) {
        _log.i('RomM: skipping thumbnail $name');
        return false;
      }

      if (romName.isNotEmpty && lower.startsWith(romName)) {
        final remainder = lower.substring(romName.length);
        // '' is the game's own name verbatim; '.state', '.state.auto', '.srm'
        // are its saves. Anything else — ' [Hacks].state' — is another title's.
        if (remainder.isNotEmpty && !remainder.startsWith('.')) {
          _log.i('RomM: skipping $name (belongs to a longer-named title)');
          return false;
        }
      }

      return true;
    }).toList();
  }

  /// Drops a single trailing extension, matching how the library indexes a
  /// ROM's name. Only the last one: a title may contain dots of its own.
  static String _romNameWithoutExtension(String romname) {
    final dot = romname.lastIndexOf('.');
    if (dot <= 0) return romname;
    final ext = romname.substring(dot);
    // Guard against clipping a title that simply ends in a period ("Mr. Do.").
    return RegExp(r'^\.[A-Za-z0-9]{1,5}$').hasMatch(ext)
        ? romname.substring(0, dot)
        : romname;
  }

  String _subfolderOf(LocalSaveFile local) {
    final parts = local.relativePath.split('/');
    if (parts.length <= 2) return '';
    return parts.sublist(1, parts.length - 1).join('/');
  }

  /// The subfolder a downloaded file belongs in under *this* device's RetroArch
  /// save/state directory — its per-core folder, or `''` for the directory root.
  ///
  /// Placement is a local question and is answered locally. The alternative,
  /// replaying a subfolder recorded on the server, breaks the moment two
  /// devices are configured differently: a handheld with
  /// `sort_savestates_enable` on wants `states/FCEUmm/`, while a Steam Deck
  /// with it off wants the root — and whichever uploaded first would dictate a
  /// path the other's emulator never reads.
  ///
  /// The RetroArch setting decides *whether* there is a subfolder; the core
  /// name is taken from an existing local file of the same kind when one is
  /// present (ground truth, and immune to core renames) and derived from the
  /// emulator's name otherwise.
  Future<String> _localSubfolder(
    GameModel game,
    bool isState,
    List<LocalSaveFile> localFiles,
  ) async {
    try {
      final cfg = await RetroArchConfigService().getMergedConfig();
      final sorts = isState
          ? cfg.sortSavestatesByCore
          : cfg.sortSavefilesByCore;
      if (!sorts) return '';

      final prefix = isState ? 'states/' : 'saves/';
      for (final f in localFiles) {
        if (!f.relativePath.startsWith(prefix)) continue;
        final sub = _subfolderOf(f);
        if (sub.isNotEmpty) return sub;
      }

      final folder = game.systemFolderName;
      if (folder == null || folder.isEmpty) return '';
      final system = await SystemRepository.getSystemByFolderName(folder);
      if (system?.id == null) return '';
      final emulator =
          await EmulatorRepository.getUserDefaultEmulatorForSystem(
            system!.id!,
          ) ??
          await EmulatorRepository.getDefaultEmulatorForSystem(system.id!);
      return RetroArchConfigService.coreFolderName(emulator?.name) ?? '';
    } catch (e) {
      // Placement is a best-effort refinement; the directory root is always a
      // valid destination and must never be the reason a sync fails.
      _log.w('RomM: could not resolve local save subfolder: $e');
      return '';
    }
  }

  /// A `403` that reaches the provider is a *persistent* permission denial: the
  /// service layer ([RommService._sendWithAuthRetry]) already re-authenticated
  /// and retried once, so a stale/empty-scope token would have recovered. What
  /// remains is a genuine authorization failure — e.g. a RomM 5.0 account that
  /// lacks `assets.write` under the granular per-user permission system.
  ///
  /// These must abort the sync with an error status; swallowing them to a
  /// `false` (no-op) return would make a dropped save look like a clean,
  /// up-to-date sync — silently losing the user's progress.
  @visibleForTesting
  static bool isPermissionDenied(Object e) =>
      e is RommException && e.statusCode == 403;

  /// Sends [local] to RomM, updating [existing] in place when the asset is
  /// already there and creating it otherwise.
  ///
  /// The update path matters: see [RommService.updateSave] for why a repeat
  /// `POST` corrupts the row/file relationship instead of overwriting.
  Future<bool> _upload(
    int romId,
    LocalSaveFile local,
    bool isState, {
    RommAsset? existing,
  }) async {
    try {
      final file = File(local.filePath);
      if (!await file.exists()) return false;
      final RommAsset asset;
      if (existing != null) {
        asset = isState
            ? await _svc.updateState(existing.id, file)
            : await _svc.updateSave(existing.id, file);
      } else {
        asset = isState
            ? await _svc.uploadState(romId, file, emulator: _assetLabel)
            : await _svc.uploadSave(romId, file, emulator: _assetLabel);
      }
      final stat = await file.stat();
      await SyncRepository.saveSyncState(
        kProviderId,
        local.filePath,
        stat.modified.millisecondsSinceEpoch,
        asset.updatedAtMs,
        local.fileSize,
        fileHash: asset.contentHash,
      );
      return true;
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM upload failed (${local.filePath}): $e');
      return false;
    }
  }

  Future<bool> _download(
    GameModel game,
    RommAsset asset, {
    required List<LocalSaveFile> localFiles,
    SyncDeadline? deadline,
  }) async {
    try {
      // Placement comes from this device's own RetroArch layout, never from the
      // asset's `emulator` field — that value belongs to whichever device
      // created the asset and says nothing about where this one reads saves.
      final prefix = asset.isState ? 'states' : 'saves';
      final sub = await _localSubfolder(game, asset.isState, localFiles);
      final relativeName = sub.isNotEmpty
          ? '$prefix/$sub/${asset.fileName}'
          : '$prefix/${asset.fileName}';
      final targets = await _resolveTargets(game, relativeName);
      if (targets.isEmpty) {
        _log.w('RomM download: no local target for ${asset.fileName}');
        return false;
      }
      // Both saves and states download via the asset's download_path; only
      // saves have the /content convenience route (used as a fallback).
      final Uint8List bytes;
      final dp = asset.downloadPath;
      if (dp != null && dp.isNotEmpty) {
        bytes = await _svc.downloadAssetByPath(dp);
      } else if (!asset.isState) {
        bytes = await _svc.downloadSaveContent(asset.id);
      } else {
        _log.w('RomM download: state ${asset.fileName} has no download_path');
        return false;
      }

      // Pre-launch deadline guard: the network fetch is done, but if the
      // launch-blocking wait has already elapsed the game is running on the
      // local save. Abandon here — before any write — so we never clobber the
      // .srm the emulator now has open or record bogus sync state.
      if (deadline?.isExpired ?? false) {
        _log.i(
          'RomM download: abandon ${asset.fileName} (launch deadline passed)',
        );
        return false;
      }

      var wroteAny = false;
      for (final target in targets) {
        final f = File(target);
        // Per-target guard (mirrors NeoSync): never overwrite a copy that is
        // newer than the remote asset. resolveLocalTargetPaths can return
        // several folders and the higher-level decision only inspected one, so
        // a different folder may hold newer local progress we must not clobber.
        if (await f.exists()) {
          final localMs = (await f.stat()).modified.millisecondsSinceEpoch;
          if (localMs > asset.updatedAtMs + _mtimeToleranceMs) {
            _log.i('RomM download: skip $target (local newer than remote)');
            continue;
          }
        }
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
        final stat = await f.stat();
        await SyncRepository.saveSyncState(
          kProviderId,
          target,
          stat.modified.millisecondsSinceEpoch,
          asset.updatedAtMs,
          bytes.length,
          fileHash: asset.contentHash,
        );
        wroteAny = true;
      }
      return wroteAny;
    } catch (e) {
      if (isPermissionDenied(e)) rethrow;
      _log.e('RomM download failed (${asset.fileName}): $e');
      return false;
    }
  }

  // ── Game-specific sync operations (interface) ───────────────────────────────

  /// Records [game] as failed in the visible sync state and returns the matching
  /// fail result. Used by every per-game sync entry point so a hard failure
  /// (notably a RomM 5.0 permission denial that [isPermissionDenied] let bubble
  /// up) surfaces as an error state instead of leaving stale state that would
  /// read as a clean, up-to-date sync.
  SyncResult _failGame(GameModel game, Object error) {
    _gameSyncStates[game.romname] = _buildState(
      game,
      GameSyncStatus.error,
      errorMessage: error.toString(),
    );
    notifyListeners();
    return SyncResult.fail(SyncError.unknown, message: error.toString());
  }

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) async {
    try {
      final status = await _syncGame(game, downloadOnly: false);
      _gameSyncStates[game.romname] = _buildState(game, status);
      notifyListeners();
      return SyncResult.ok();
    } catch (e) {
      return _failGame(game, e);
    }
  }

  @override
  GameSyncState? getGameSyncState(String gameId) => _gameSyncStates[gameId];

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async {
    try {
      final status = await _syncGame(
        game,
        downloadOnly: true,
        deadline: deadline,
      );
      if (status == GameSyncStatus.error) {
        // A status-level failure (server unreachable, listing failed) must be
        // as visible as a thrown one: record the error state and report
        // failure. The launch flow treats any failure as best-effort, so this
        // never blocks the game from starting — it only keeps the UI honest.
        return _failGame(game, _browse.lastError ?? 'RomM save sync failed');
      }
      return SyncResult.ok();
    } catch (e) {
      // Surface a permission denial (or any hard failure) as an error state so a
      // dropped pre-launch download isn't invisible; without this the UI would
      // keep whatever state it had and read as a clean sync.
      return _failGame(game, e);
    }
  }

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    return detectGameSaveFiles(game);
  }

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    final existing = _gameSyncStates[gameId];
    if (existing != null) {
      _gameSyncStates[gameId] = existing.copyWith(
        cloudEnabled: enabled,
        status: enabled ? existing.status : GameSyncStatus.disabled,
      );
      notifyListeners();
    }
  }

  // ── Core sync operations (interface) ────────────────────────────────────────

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async {
    final romId = int.tryParse(gameId);
    if (romId == null) {
      return SyncResult.fail(
        SyncError.configInvalid,
        message: 'uploadSave expects a RomM rom_id',
      );
    }
    try {
      await _svc.uploadSave(romId, file);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.networkError, message: e.toString());
    }
  }

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async {
    final assetId = int.tryParse(fileId);
    if (assetId == null) {
      return SyncResult.fail(SyncError.fileNotFound, message: 'Invalid fileId');
    }
    try {
      final bytes = await _svc.downloadSaveContent(assetId);
      return SyncResult.ok(data: bytes);
    } catch (e) {
      return SyncResult.fail(SyncError.networkError, message: e.toString());
    }
  }

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async {
    final romId = gameId == null ? null : int.tryParse(gameId);
    if (romId == null) return const [];
    try {
      // Independent GETs → fetch concurrently rather than serially.
      final results = await Future.wait([
        _svc.listSaves(romId: romId),
        _svc.listStates(romId: romId),
      ]);
      final assets = [...results[0], ...results[1]];
      return assets
          .map(
            (a) => SyncFile(
              id: a.id.toString(),
              fileName: a.fileName,
              gameId: gameId,
              fileSize: a.fileSizeBytes,
              uploadedAt: a.createdAt ?? DateTime.now(),
              modifiedAt: a.updatedAt,
              checksum: a.contentHash,
            ),
          )
          .toList();
    } catch (e) {
      _log.e('RomM listSaves failed: $e');
      return const [];
    }
  }

  @override
  Future<SyncResult> fullSync() async {
    if (!_browse.isConnected) {
      return SyncResult.fail(SyncError.authRequired);
    }
    // Per-game sync is driven by the launch flow; a global pass would require
    // enumerating mapped games. Deferred — return ok as a no-op for now.
    return SyncResult.ok(message: 'RomM syncs per-game on launch/close');
  }

  @override
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.fail(
    SyncError.unknown,
    message: 'deleteRemote not supported by $providerId',
  );

  @override
  Future<SyncQuota?> getQuota() async => null;
}
