import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';

/// On-disk cache of raw RetroAchievements API responses.
///
/// Each successful fetch stores the decoded JSON payload keyed by endpoint +
/// username. When the network is unavailable the service layer replays the
/// stored payload through the same `fromJson` parsers, so a signed-in user
/// keeps a fully-populated (if stale) dashboard offline instead of being
/// bounced back to the login form.
///
/// Only data that is safe to show while offline is cached here — never the
/// API key (that lives in secure storage).
class RetroAchievementsCache {
  RetroAchievementsCache._();

  static final _log = LoggerService.instance;
  static String? _cachedDir;

  /// Whether the most recent cache-aware fetch was served from disk rather
  /// than the live API. Read immediately after an awaited fetch to decide
  /// whether the session is running in offline mode. Single-user, sequential
  /// auto-login makes this safe without per-call plumbing.
  static bool lastServedFromCache = false;

  static void markServedFromCache() => lastServedFromCache = true;
  static void markServedLive() => lastServedFromCache = false;

  static Future<String> _dir() async {
    if (_cachedDir != null) return _cachedDir!;
    final base = await ConfigService.getUserDataPath();
    _cachedDir = path.join(base, 'ra_cache');
    return _cachedDir!;
  }

  /// Filesystem-safe filename for a cache key.
  static String _sanitize(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  static Future<File> _fileFor(String key) async {
    final dir = await _dir();
    return File(path.join(dir, '${_sanitize(key)}.json'));
  }

  /// Persists a decoded JSON [payload] under [key], overwriting any prior copy.
  static Future<void> save(String key, dynamic payload) async {
    try {
      final file = await _fileFor(key);
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(payload));
    } catch (e) {
      // A cache write failure must never break a live fetch — just log it.
      _log.w('RA cache: failed to save "$key": $e');
    }
  }

  /// Returns the decoded JSON payload stored under [key], or null if absent
  /// or unreadable.
  static Future<dynamic> load(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists()) return null;
      return json.decode(await file.readAsString());
    } catch (e) {
      _log.w('RA cache: failed to load "$key": $e');
      return null;
    }
  }

  /// Removes every cached response (used when the user disconnects).
  static Future<void> clear() async {
    try {
      final dir = Directory(await _dir());
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      _log.w('RA cache: failed to clear: $e');
    }
  }
}
