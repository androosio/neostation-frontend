import 'package:flutter/foundation.dart';

import '../models/romm_rom.dart';
import '../models/romm_rom_page.dart';
import '../services/logger_service.dart';
import 'romm_provider.dart';

/// Fetches one page of the source being synced. Offset/limit paging only — the
/// filter (platform, collection, search) is bound by whoever supplies this.
typedef RommPageFetcher =
    Future<RommRomPage> Function({required int limit, required int offset});

/// True when [rom] is already on disk and should be skipped.
typedef RommDownloadedCheck = Future<bool> Function(RommRom rom);

/// Downloads one ROM, resolving to its final [RommDownload] record.
typedef RommRomDownloader = Future<RommDownload> Function(RommRom rom);

/// What a bulk sync is doing right now.
enum RommBulkSyncPhase {
  /// No sync running (either never started or finished).
  idle,

  /// Paging the source to learn the full ROM set and filtering out what is
  /// already on disk. The download queue isn't known yet.
  preparing,

  /// Working through the queue.
  downloading,
}

/// Downloads an entire RomM platform or collection in one action.
///
/// Deliberately a [ChangeNotifier] of its own rather than more state on
/// [RommProvider]: a running sync ticks constantly, and the browse screen
/// watches the provider for its ROM list. Folding progress into the provider
/// would rebuild the whole browse tree on every queue step, which is the shape
/// of jank this app has been bitten by before. Listening here rebuilds only the
/// progress UI.
///
/// It is owned by the provider (not the screen) so a sync survives leaving the
/// tab, and so [RommProvider.disconnect] can stop it.
///
/// Per-ROM byte progress is intentionally *not* mirrored here — it already
/// lives on [RommProvider.downloadFor] for the ids in [activeRomIds], and
/// copying it would reintroduce the per-chunk notify storm this class exists to
/// avoid. Aggregate counters move once per queue item.
class RommBulkSync extends ChangeNotifier {
  static final _log = LoggerService.instance;

  /// Simultaneous transfers. One at a time is slow on a large platform; letting
  /// the whole queue run at once saturates a handheld's wifi and the server.
  /// Three is a starting point to be tuned against a real server on device.
  static const int defaultConcurrency = 3;

  /// Rows per enumeration request. Larger than the browse page size (50): this
  /// pass is a means to an end, not something the user scrolls, so the round
  /// trips matter more than the latency of any one of them.
  static const int defaultPageSize = 500;

  /// Hard stop on the enumeration loop, in pages. A server that keeps returning
  /// full pages (a `total` that never agrees with the rows, a filter the server
  /// ignores) would otherwise page forever. 500 × 500 = 250k ROMs, far past any
  /// real library.
  static const int _maxPages = 500;

  RommBulkSyncPhase _phase = RommBulkSyncPhase.idle;
  String _sourceLabel = '';
  bool _cancelRequested = false;

  int _enumerated = 0;
  int _enumerateTotal = 0;

  final List<RommRom> _queue = [];
  int _completed = 0;
  int _failed = 0;
  int _skipped = 0;
  int _cancelled = 0;
  int _doneBytes = 0;
  int _queuedBytes = 0;

  final Set<int> _activeRomIds = {};

  RommDownloadError? _lastError;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// [notifyListeners] that tolerates being disposed mid-run.
  ///
  /// A sync outlives the screen that started it and is only torn down with the
  /// app, so the last few queue steps can land after disposal; notifying then
  /// would throw out of a worker for no useful reason.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ── Getters ────────────────────────────────────────────────────────────────

  RommBulkSyncPhase get phase => _phase;
  bool get isRunning => _phase != RommBulkSyncPhase.idle;

  /// Name of the platform/collection being synced (for the progress UI).
  String get sourceLabel => _sourceLabel;

  /// True once cancellation was asked for, while the queue winds down.
  bool get cancelRequested => _cancelRequested;

  /// ROMs seen so far by the enumeration pass, and the server's reported total
  /// for the query. Both are 0 outside [RommBulkSyncPhase.preparing].
  int get enumerated => _enumerated;
  int get enumerateTotal => _enumerateTotal;

  /// ROMs actually queued for download (the enumeration minus what was already
  /// on disk).
  int get total => _queue.length;

  int get completed => _completed;
  int get failed => _failed;

  /// ROMs the enumeration pass found already on disk and never queued.
  int get skipped => _skipped;

  /// Queue items abandoned because the sync was cancelled mid-flight.
  int get cancelled => _cancelled;

  /// Queue items that have reached a terminal state, however they got there.
  int get finished => _completed + _failed + _cancelled;

  /// Bytes of successfully downloaded ROMs, against the queue's total size.
  /// Both come from RomM's `fs_size_bytes`, so they count what the *server*
  /// holds — an unpacked multi-disc archive occupies more on disk than this.
  int get doneBytes => _doneBytes;
  int get totalBytes => _queuedBytes;

  /// ROM ids transferring right now. The UI reads live byte progress for these
  /// from [RommProvider.downloadFor].
  Set<int> get activeRomIds => Set.unmodifiable(_activeRomIds);

  /// Why the most recent failure failed, or null when nothing has failed.
  /// A whole-queue outcome, not per ROM: the last failure wins.
  RommDownloadError? get lastError => _lastError;

  // ── Running ────────────────────────────────────────────────────────────────

  /// Enumerates [fetchPage]'s full result set, drops what [isDownloaded]
  /// reports as already local, and runs the rest through [download] with at
  /// most [concurrency] transfers in flight.
  ///
  /// [cancelDownload] is invoked for each in-flight ROM when [cancel] is
  /// called, so cancelling stops the transfers as well as the queue.
  ///
  /// Never throws: a failure to enumerate ends the sync with [lastError] set,
  /// and a failing ROM is counted and stepped over. Returns when the queue is
  /// drained (or abandoned).
  ///
  /// No-op while another sync is running — one at a time, by design.
  Future<void> run({
    required String sourceLabel,
    required RommPageFetcher fetchPage,
    required RommDownloadedCheck isDownloaded,
    required RommRomDownloader download,
    void Function(int romId)? cancelDownload,
    int concurrency = defaultConcurrency,
    int pageSize = defaultPageSize,
  }) async {
    if (isRunning) return;

    _reset();
    _sourceLabel = sourceLabel;
    _phase = RommBulkSyncPhase.preparing;
    _notify();

    try {
      await _enumerate(fetchPage, isDownloaded, pageSize);
      if (_cancelRequested || _queue.isEmpty) return;

      _phase = RommBulkSyncPhase.downloading;
      _notify();
      await _drain(download, cancelDownload, concurrency);
    } finally {
      _activeRomIds.clear();
      _phase = RommBulkSyncPhase.idle;
      _notify();
    }
  }

  /// Asks the sync to stop: the queue stops handing out work and every transfer
  /// in flight is cancelled. Whatever has already landed stays on disk.
  void cancel() {
    if (!isRunning || _cancelRequested) return;
    _cancelRequested = true;
    // Reach the transfers themselves, not just the queue — otherwise cancelling
    // would leave the user waiting on up to [concurrency] multi-GB ROMs.
    final cancelDownload = _cancelDownload;
    if (cancelDownload != null) {
      for (final id in _activeRomIds.toList()) {
        cancelDownload(id);
      }
    }
    _notify();
  }

  /// Per-ROM cancel hook for the run in progress (null while idle).
  void Function(int romId)? _cancelDownload;

  /// Clears the counters from the last run so the UI can dismiss its summary.
  /// No-op while a sync is running.
  void clear() {
    if (isRunning) return;
    _reset();
    _notify();
  }

  void _reset() {
    _cancelRequested = false;
    _sourceLabel = '';
    _enumerated = 0;
    _enumerateTotal = 0;
    _queue.clear();
    _completed = 0;
    _failed = 0;
    _skipped = 0;
    _cancelled = 0;
    _doneBytes = 0;
    _queuedBytes = 0;
    _activeRomIds.clear();
    _lastError = null;
  }

  /// Pages the whole source into [_queue], skipping ROMs already on disk.
  ///
  /// Filtering per page (rather than collecting everything and filtering after)
  /// keeps the queue and its byte total growing while the pass runs, so the
  /// progress UI has something truthful to show on a large platform.
  Future<void> _enumerate(
    RommPageFetcher fetchPage,
    RommDownloadedCheck isDownloaded,
    int pageSize,
  ) async {
    var offset = 0;
    for (var page = 0; page < _maxPages; page++) {
      if (_cancelRequested) return;

      final RommRomPage result;
      try {
        result = await fetchPage(limit: pageSize, offset: offset);
      } catch (e) {
        _log.e('RomM bulk sync: enumeration failed at offset $offset: $e');
        _lastError = RommDownloadError.network;
        return;
      }

      // RomM reports the match count for the whole query, which is the only
      // honest denominator while paging.
      if (result.total > 0) _enumerateTotal = result.total;

      for (final rom in result.items) {
        if (_cancelRequested) return;
        _enumerated++;
        if (await isDownloaded(rom)) {
          _skipped++;
        } else {
          _queue.add(rom);
          _queuedBytes += rom.fsSizeBytes;
        }
      }
      _notify();

      offset += result.items.length;
      // A short page is the end of the results. An empty one also guards the
      // pathological case of a server that ignores the offset.
      if (result.items.length < pageSize) return;
      if (_enumerateTotal > 0 && offset >= _enumerateTotal) return;
    }
    _log.w(
      'RomM bulk sync: enumeration hit the $_maxPages-page cap for '
      '"$_sourceLabel" — syncing the ${_queue.length} ROMs found so far',
    );
  }

  /// Runs the queue through [concurrency] workers.
  ///
  /// The workers share a cursor rather than being handed fixed slices, so a
  /// worker stuck on a 4 GB disc image doesn't leave its share of the small
  /// ROMs waiting behind it. Dart's single-threaded event loop makes the
  /// cursor increment safe without a lock.
  Future<void> _drain(
    RommRomDownloader download,
    void Function(int romId)? cancelDownload,
    int concurrency,
  ) async {
    var cursor = 0;
    final workers = concurrency < 1 ? 1 : concurrency;

    Future<void> worker() async {
      while (true) {
        if (_cancelRequested || cursor >= _queue.length) return;
        final rom = _queue[cursor++];

        // Registering the id and starting the transfer happen in one
        // synchronous run, so [cancel] can never land between them and miss a
        // download that has no tracker yet.
        _activeRomIds.add(rom.id);
        _notify();
        try {
          final result = await download(rom);
          switch (result.status) {
            case RommDownloadStatus.completed:
              _completed++;
              _doneBytes += rom.fsSizeBytes;
              break;
            case RommDownloadStatus.cancelled:
              _cancelled++;
              break;
            case RommDownloadStatus.failed:
            case RommDownloadStatus.downloading:
              // `downloading` shouldn't reach here — downloadRom resolves only
              // on a terminal state — but treating an unfinished transfer as a
              // success would overstate what landed on disk.
              _failed++;
              if (result.error != RommDownloadError.none) {
                _lastError = result.error;
              }
              break;
          }
        } catch (e) {
          // downloadRom reports failures through the record rather than
          // throwing, so this is belt-and-braces: one bad ROM must not abandon
          // the rest of the queue.
          _log.e('RomM bulk sync: ${rom.fsName} threw: $e');
          _failed++;
          _lastError = RommDownloadError.network;
        } finally {
          _activeRomIds.remove(rom.id);
          _notify();
        }
      }
    }

    _cancelDownload = cancelDownload;
    try {
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    } finally {
      _cancelDownload = null;
      // Anything never handed out was abandoned by the cancel.
      if (_cancelRequested && cursor < _queue.length) {
        _cancelled += _queue.length - cursor;
      }
    }
  }
}
