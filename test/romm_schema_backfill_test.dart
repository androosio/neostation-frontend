import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v113, which repairs databases that skipped the RomM
/// table creations because this branch renumbered them.
///
/// Background: the RomM tables have moved versions repeatedly as main landed
/// its own migrations (v97 → v98 → v106 → v107/v108/v110). A device upgraded
/// by an older RomM build therefore sits at a `user_version` at or above the
/// number that *now* creates `user_romm_config`, so that migration never runs
/// again and the table is missing forever — every launch then logs
/// "no such table: user_romm_config" and the RomM tab, save sync and playtime
/// sync all fail. v113 replays the creations; it must be a no-op for databases
/// that already have them.
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV113() => SqliteMigrations.migrateToVersion(db, 113);

  bool tableExists(String name) => db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
    [name],
  ).isNotEmpty;

  Set<String> columnsOf(String table) => db
      .select('PRAGMA table_info($table)')
      .map((r) => r['name'].toString())
      .toSet();

  test('creates every RomM table on a database that skipped them', () async {
    expect(tableExists('user_romm_config'), isFalse);

    await runV113();

    expect(tableExists('user_romm_config'), isTrue);
    expect(tableExists('app_romm_rom_map'), isTrue);
    expect(tableExists('app_romm_play_sessions'), isTrue);
    expect(tableExists('app_romm_playtime_state'), isTrue);
    expect(tableExists('app_neo_sync_state'), isTrue);
  });

  test(
    'is a no-op when the tables already exist, keeping their rows',
    () async {
      db.execute(SqliteMigrations.createUserRommConfigTableSql);
      db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      db.execute(SqliteMigrations.createAppRommRomMapIndexSql);
      db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
      db.execute(SqliteMigrations.createAppRommPlaySessionsIndexSql);
      db.execute(SqliteMigrations.createAppRommPlaytimeStateTableSql);
      db.execute(
        "INSERT INTO user_romm_config (id, server_url, username) "
        "VALUES (1, 'https://romm.local', 'testuser')",
      );

      await runV113();

      final rows = db.select(
        'SELECT server_url, username FROM user_romm_config',
      );
      expect(rows, hasLength(1));
      expect(rows.first['server_url'], 'https://romm.local');
      expect(rows.first['username'], 'testuser');
    },
  );

  test('provider-scopes a legacy app_neo_sync_state that skipped v109', () async {
    // The pre-v109 shape: keyed on file_path alone, no provider column.
    db.execute('''
      CREATE TABLE app_neo_sync_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_path TEXT NOT NULL UNIQUE,
        local_modified_at INTEGER NOT NULL,
        cloud_updated_at INTEGER NOT NULL,
        file_size INTEGER NOT NULL,
        file_hash TEXT
      )
    ''');
    db.execute(
      "INSERT INTO app_neo_sync_state "
      "(file_path, local_modified_at, cloud_updated_at, file_size, file_hash) "
      "VALUES ('/saves/game.srm', 1, 2, 3, 'abc')",
    );

    await runV113();

    expect(columnsOf('app_neo_sync_state'), contains('provider'));
    final rows = db.select(
      'SELECT provider, file_path, file_hash FROM app_neo_sync_state',
    );
    expect(rows, hasLength(1));
    // Historic rows were all written by NeoSync, so they must be attributed to
    // it rather than silently inherited by RomM.
    expect(rows.first['provider'], 'neosync');
    expect(rows.first['file_path'], '/saves/game.srm');
    expect(rows.first['file_hash'], 'abc');
  });

  test('lets both providers hold state for the same file afterwards', () async {
    await runV113();

    db.execute(
      "INSERT INTO app_neo_sync_state "
      "(provider, file_path, local_modified_at, cloud_updated_at, file_size) "
      "VALUES ('neosync', '/saves/game.srm', 1, 2, 3)",
    );
    db.execute(
      "INSERT INTO app_neo_sync_state "
      "(provider, file_path, local_modified_at, cloud_updated_at, file_size) "
      "VALUES ('romm', '/saves/game.srm', 4, 5, 6)",
    );

    final rows = db.select(
      'SELECT provider FROM app_neo_sync_state ORDER BY provider',
    );
    expect(rows.map((r) => r['provider']), ['neosync', 'romm']);
  });
}
