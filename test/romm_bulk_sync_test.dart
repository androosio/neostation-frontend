import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/providers/romm_bulk_sync.dart';
import 'package:neostation/providers/romm_provider.dart';

/// Covers the bulk-sync engine: enumeration paging, the already-downloaded
/// filter, the bounded worker pool, and cancellation.
///
/// [RommBulkSync.run] takes its server/disk access as callbacks precisely so
/// this can be exercised without a RomM server or a filesystem — the fakes
/// below stand in for `getRomsPage`, `isDownloadedCached` and `downloadRom`.

RommRom _rom(int id, {int sizeBytes = 0}) => RommRom(
  id: id,
  name: 'Game $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: 'game$id.sfc',
  fsNameNoExt: 'game$id',
  fsExtension: 'sfc',
  fsSizeBytes: sizeBytes,
);

RommDownload _completed(RommRom rom) =>
    RommDownload(romId: rom.id, status: RommDownloadStatus.completed);

RommDownload _failed(
  RommRom rom, [
  RommDownloadError error = RommDownloadError.network,
]) => RommDownload(
  romId: rom.id,
  status: RommDownloadStatus.failed,
  error: error,
);

/// A page fetcher over a fixed ROM list, honouring limit/offset the way RomM
/// does (and reporting the full match count as `total`).
RommPageFetcher _pagesOver(List<RommRom> all, {List<int>? requestedOffsets}) {
  return ({required int limit, required int offset}) async {
    requestedOffsets?.add(offset);
    final end = (offset + limit).clamp(0, all.length);
    return RommRomPage(
      items: offset >= all.length ? const [] : all.sublist(offset, end),
      total: all.length,
    );
  };
}

Future<bool> _nothingDownloaded(RommRom _) async => false;

void main() {
  group('enumeration', () {
    test('pages the whole source and queues every ROM', () async {
      final all = [for (var i = 0; i < 25; i++) _rom(i)];
      final offsets = <int>[];
      final downloaded = <int>[];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all, requestedOffsets: offsets),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloaded.add(rom.id);
          return _completed(rom);
        },
        pageSize: 10,
        concurrency: 1,
      );

      expect(offsets, [0, 10, 20]);
      expect(downloaded.length, 25);
      expect(sync.completed, 25);
      expect(sync.total, 25);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });

    test('stops once the server-reported total is reached', () async {
      // A page that comes back exactly full at the end of the results must not
      // trigger another request.
      final all = [for (var i = 0; i < 20; i++) _rom(i)];
      final offsets = <int>[];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all, requestedOffsets: offsets),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
        pageSize: 10,
        concurrency: 1,
      );

      expect(offsets, [0, 10]);
      expect(sync.completed, 20);
    });

    test('ROMs already on disk are skipped, not queued', () async {
      final all = [for (var i = 0; i < 6; i++) _rom(i)];
      final downloaded = <int>[];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id.isEven,
        download: (rom) async {
          downloaded.add(rom.id);
          return _completed(rom);
        },
        concurrency: 1,
      );

      expect(downloaded, [1, 3, 5]);
      expect(sync.skipped, 3);
      expect(sync.total, 3);
      expect(sync.enumerated, 6);
    });

    test('queued bytes count only what is actually downloaded', () async {
      final all = [
        _rom(1, sizeBytes: 100),
        _rom(2, sizeBytes: 200), // already local
        _rom(3, sizeBytes: 300),
      ];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: (rom) async => rom.id == 2,
        download: (rom) async => rom.id == 3 ? _failed(rom) : _completed(rom),
        concurrency: 1,
      );

      expect(sync.totalBytes, 400, reason: 'the skipped ROM is not queued');
      expect(sync.doneBytes, 100, reason: 'only the successful ROM counts');
    });

    test('an enumeration failure ends the sync without downloading', () async {
      var downloads = 0;
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: ({required int limit, required int offset}) async {
          throw StateError('server down');
        },
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
      );

      expect(downloads, 0);
      expect(sync.lastError, RommDownloadError.network);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });
  });

  group('worker pool', () {
    test('never exceeds the concurrency cap', () async {
      final all = [for (var i = 0; i < 12; i++) _rom(i)];
      final gates = <int, Completer<void>>{};
      var inFlight = 0;
      var peak = 0;
      final sync = RommBulkSync();

      final run = sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          final gate = gates[rom.id] = Completer<void>();
          await gate.future;
          inFlight--;
          return _completed(rom);
        },
        concurrency: 3,
      );

      // Release transfers one at a time; each completion should let exactly one
      // more start, holding the pool at its cap.
      for (var released = 0; released < all.length; released++) {
        await pumpEventQueue();
        expect(inFlight, lessThanOrEqualTo(3));
        final pending = gates.values.where((g) => !g.isCompleted).toList();
        expect(pending, isNotEmpty);
        pending.first.complete();
      }
      await run;

      expect(peak, 3);
      expect(sync.completed, 12);
    });

    test('a failing ROM is counted and the queue carries on', () async {
      final all = [for (var i = 0; i < 5; i++) _rom(i)];
      final sync = RommBulkSync();

      await sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => rom.id == 2
            ? _failed(rom, RommDownloadError.noWritableFolder)
            : _completed(rom),
        concurrency: 2,
      );

      expect(sync.completed, 4);
      expect(sync.failed, 1);
      expect(sync.lastError, RommDownloadError.noWritableFolder);
      expect(sync.finished, 5);
    });

    test(
      'a download that throws does not abandon the rest of the queue',
      () async {
        final all = [for (var i = 0; i < 5; i++) _rom(i)];
        final sync = RommBulkSync();

        await sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async {
            if (rom.id == 1) throw StateError('disk exploded');
            return _completed(rom);
          },
          concurrency: 1,
        );

        expect(sync.completed, 4);
        expect(sync.failed, 1);
      },
    );

    test('a second run is a no-op while one is in flight', () async {
      final all = [for (var i = 0; i < 3; i++) _rom(i)];
      final gate = Completer<void>();
      var starts = 0;
      final sync = RommBulkSync();

      final first = sync.run(
        sourceLabel: 'SNES',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          starts++;
          await gate.future;
          return _completed(rom);
        },
        concurrency: 1,
      );
      await pumpEventQueue();

      await sync.run(
        sourceLabel: 'Mega Drive',
        fetchPage: _pagesOver(all),
        isDownloaded: _nothingDownloaded,
        download: (rom) async => _completed(rom),
      );
      expect(sync.sourceLabel, 'SNES', reason: 'the running sync is untouched');

      gate.complete();
      await first;
      expect(starts, 3);
    });
  });

  _writeProbeTests();

  group('cancellation', () {
    test(
      'stops handing out work and cancels the transfers in flight',
      () async {
        final all = [for (var i = 0; i < 10; i++) _rom(i)];
        final gates = <int, Completer<void>>{};
        final cancelledIds = <int>[];
        var started = 0;
        final sync = RommBulkSync();

        final run = sync.run(
          sourceLabel: 'SNES',
          fetchPage: _pagesOver(all),
          isDownloaded: _nothingDownloaded,
          download: (rom) async {
            started++;
            final gate = gates[rom.id] = Completer<void>();
            await gate.future;
            // Mirrors the real downloader: a cancelled transfer resolves to a
            // cancelled record rather than throwing.
            return RommDownload(
              romId: rom.id,
              status: cancelledIds.contains(rom.id)
                  ? RommDownloadStatus.cancelled
                  : RommDownloadStatus.completed,
            );
          },
          cancelDownload: cancelledIds.add,
          concurrency: 2,
        );
        await pumpEventQueue();
        expect(started, 2);

        sync.cancel();
        expect(sync.cancelRequested, isTrue);
        expect(
          cancelledIds..sort(),
          [0, 1],
          reason:
              'the two in-flight transfers are cancelled, not just the queue',
        );

        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await run;

        expect(started, 2, reason: 'no further ROMs were handed out');
        expect(
          sync.cancelled,
          10,
          reason: '2 abandoned in flight + 8 never started',
        );
        expect(sync.completed, 0);
        expect(sync.phase, RommBulkSyncPhase.idle);
      },
    );

    test('cancelling during enumeration never reaches the queue', () async {
      final all = [for (var i = 0; i < 100; i++) _rom(i)];
      var downloads = 0;
      final sync = RommBulkSync();
      late final RommBulkSync self;
      self = sync;

      final run = sync.run(
        sourceLabel: 'SNES',
        fetchPage: ({required int limit, required int offset}) async {
          // Cancel as soon as the first page is being served.
          Future.microtask(self.cancel);
          final end = (offset + limit).clamp(0, all.length);
          return RommRomPage(
            items: all.sublist(offset, end),
            total: all.length,
          );
        },
        isDownloaded: _nothingDownloaded,
        download: (rom) async {
          downloads++;
          return _completed(rom);
        },
        pageSize: 10,
      );
      await run;

      expect(downloads, 0);
      expect(sync.phase, RommBulkSyncPhase.idle);
    });

    test('cancel is a no-op when nothing is running', () {
      final sync = RommBulkSync();
      sync.cancel();
      expect(sync.cancelRequested, isFalse);
      expect(sync.isRunning, isFalse);
    });
  });
}

/// Regression: a bulk sync resolves destinations for several ROMs of the same
/// system at once, and the writability probe used to be a single shared
/// filename. Concurrent probes then deleted each other's file, the loser's
/// delete threw, and the folder was reported unwritable — ROMs failed with
/// "no writable folder" on a bulk sync and then downloaded fine on a retry.
void _writeProbeTests() {
  group('dirIfWritable', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('romm_probe_test');
    });
    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    test('concurrent probes of the same directory all succeed', () async {
      final target = p.join(temp.path, 'msx');
      final results = await Future.wait([
        for (var i = 0; i < 8; i++) RommProvider.dirIfWritable(target),
      ]);

      expect(
        results.where((r) => r == null),
        isEmpty,
        reason: 'every concurrent probe must see the folder as writable',
      );
      expect(results.every((r) => r == target), isTrue);
    });

    test('leaves no probe files behind', () async {
      final target = p.join(temp.path, 'snes');
      await Future.wait([
        for (var i = 0; i < 8; i++) RommProvider.dirIfWritable(target),
      ]);

      final leftovers = Directory(target)
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('.romm_write_test'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('an unwritable destination still reports null', () async {
      // A path whose parent is a *file* can never be created as a directory.
      final blocker = File(p.join(temp.path, 'blocker'))..writeAsStringSync('');
      expect(
        await RommProvider.dirIfWritable(p.join(blocker.path, 'sub')),
        isNull,
      );
    });
  });
}
