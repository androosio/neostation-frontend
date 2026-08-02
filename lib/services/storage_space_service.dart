import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'logger_service.dart';

/// How much room is left on the volume holding a given path.
///
/// Exists for the RomM bulk sync's pre-flight check: syncing a platform can
/// mean tens of gigabytes, and finding out it doesn't fit halfway through is a
/// long wait for a pile of failed downloads.
///
/// Every path through this class **fails open** — an unmeasurable volume
/// answers null, never zero. Callers treat null as "no opinion" and carry on:
/// a storage API this app can't reach must not be able to block a download the
/// user asked for.
class StorageSpaceService {
  static final _log = LoggerService.instance;

  /// Android's `File.usableSpace`, on the channel that already carries the
  /// app's other filesystem calls.
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  /// Free bytes on the volume containing [path], or null when it can't be
  /// measured (unsupported platform, no permission, path off any volume).
  ///
  /// [path] need not exist: a download's destination folder is often created
  /// on the way in, so this measures the nearest existing ancestor instead,
  /// which is on the same volume.
  static Future<int?> freeSpaceBytes(String path) async {
    if (path.isEmpty) return null;
    final target = await _nearestExistingDir(path);
    if (target == null) return null;
    try {
      if (Platform.isAndroid) return await _viaChannel(target);
      // `df` covers Linux and macOS; Windows has no equivalent worth shelling
      // out for, and falls through to "unknown".
      if (Platform.isLinux || Platform.isMacOS) return await _viaDf(target);
    } catch (e) {
      _log.w('Free space for "$target" could not be measured: $e');
    }
    return null;
  }

  static Future<int?> _viaChannel(String path) async {
    final bytes = await _channel.invokeMethod<int>('getFreeSpace', {
      'path': path,
    });
    // The native side already maps its own 0 (unknown volume) to null; guard
    // anyway so a zero can never be mistaken for a full disk.
    return (bytes == null || bytes <= 0) ? null : bytes;
  }

  /// Parses POSIX `df -Pk`, whose second line is
  /// `filesystem 1024-blocks used available capacity mounted-on`. `-P`
  /// guarantees that one line per filesystem, so the columns can be indexed.
  static Future<int?> _viaDf(String path) async {
    final run = await Process.run('df', ['-Pk', path]);
    if (run.exitCode != 0) return null;
    final lines = '${run.stdout}'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    return parseDfOutput(lines.last);
  }

  /// Available bytes from one `df -Pk` data row, or null if it doesn't parse.
  @visibleForTesting
  static int? parseDfOutput(String line) {
    final columns = line.split(RegExp(r'\s+'));
    if (columns.length < 4) return null;
    final blocks = int.tryParse(columns[3]);
    if (blocks == null || blocks < 0) return null;
    return blocks * 1024;
  }

  /// Walks up from [path] to the first directory that exists, since a volume's
  /// free space is a property of the mount, not of a folder yet to be created.
  /// Returns null if nothing on the way up to the root exists (or can be
  /// stat'd, which is the same answer here).
  static Future<String?> _nearestExistingDir(String path) async {
    var current = p.normalize(path);
    while (true) {
      try {
        if (await Directory(current).exists()) return current;
      } catch (_) {
        // Unreadable is indistinguishable from missing for this purpose; keep
        // walking up rather than giving up on the whole probe.
      }
      final parent = p.dirname(current);
      // dirname of a root ("/" or "C:\") is itself — the end of the walk.
      if (parent == current) return null;
      current = parent;
    }
  }
}
