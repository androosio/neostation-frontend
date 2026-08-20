import 'package:flutter/foundation.dart';

import '../models/collection_model.dart';
import '../models/game_model.dart';
import '../services/collections/collections_service.dart';

/// Holds the user's collections for the widget tree.
///
/// Two consumers depend on being notified: the systems carousel/grid (the
/// Collections card's game count) and the collections browser screen.
///
/// Every mutation writes through [CollectionsService] and then re-reads the
/// list, so the game counts stay honest without a second query per collection —
/// the listing query already computes them in one `GROUP BY`.
///
/// Nothing here is static. `subDisplay()` runs a second Flutter engine that
/// shares the SQLite file and nothing in memory, so a process-wide cache would
/// go stale the moment either engine wrote (CLAUDE.md, dual-display devices).
class CollectionsProvider extends ChangeNotifier {
  List<CollectionModel> _collections = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;

  /// Every `rom_path` that belongs to at least one collection.
  ///
  /// Held here so the games views can badge a row without a query per card.
  /// Refreshed with the list itself, which is exactly when membership can have
  /// changed from this engine.
  Set<String> _memberRomPaths = const {};

  /// Bumped whenever a collection's artwork file is replaced in place.
  ///
  /// Replacing a file at the same path changes no `ValueKey`, so widgets need a
  /// value that does change to force a repaint — the same reason
  /// `SystemInfo.imageVersion` exists.
  int _imageVersion = 0;

  /// The collections, ordered by `sort_order` then name.
  List<CollectionModel> get collections => List.unmodifiable(_collections);

  /// True while a [load] is in flight.
  bool get isLoading => _isLoading;

  /// True once the first [load] has completed, successfully or not.
  bool get hasLoaded => _hasLoaded;

  /// Number of distinct games filed in at least one collection.
  ///
  /// The only "how many games do my collections hold" answer there is, by
  /// decision: a game in three collections is one game, and a rollup that can
  /// exceed the size of the library reads as a bug. A getter that summed the
  /// per-collection counts existed alongside this one and was deleted rather
  /// than left as a second, disagreeing answer for a future caller to reach
  /// for by accident.
  ///
  /// Note this is only in tension *across* collections. Within one,
  /// `CollectionModel.gameCount` is already distinct and needs no `DISTINCT`:
  /// `user_collection_items` is keyed on `(collection_id, rom_path)`, so the
  /// same game cannot be filed in one collection twice.
  ///
  /// Free: [_memberRomPaths] is already loaded for the games views' badge.
  int get memberGameCount => _memberRomPaths.length;

  /// Cache-busting counter for collection artwork.
  int get imageVersion => _imageVersion;

  /// Whether [romPath] is filed in any collection.
  ///
  /// Membership of a *particular* collection still needs [collectionIdsFor];
  /// this answers only the question a badge asks.
  bool isInAnyCollection(String? romPath) =>
      romPath != null &&
      romPath.isNotEmpty &&
      _memberRomPaths.contains(romPath);

  /// Returns the collection with [id], or null if it is not loaded.
  CollectionModel? byId(String id) {
    for (final collection in _collections) {
      if (collection.id == id) return collection;
    }
    return null;
  }

  /// Re-reads every collection (and its game count) from the database.
  ///
  /// Safe to call repeatedly; concurrent calls collapse into the first.
  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    notifyListeners();

    try {
      _collections = await CollectionsService.getCollections();
      _memberRomPaths = await CollectionsService.memberRomPaths();
    } finally {
      _isLoading = false;
      _hasLoaded = true;
      notifyListeners();
    }
  }

  /// Creates a collection and returns it, refreshing the list.
  Future<CollectionModel> create(String name, {String? imageSourcePath}) async {
    final created = await CollectionsService.createCollection(
      name,
      imageSourcePath: imageSourcePath,
    );
    await _refresh();
    return created;
  }

  /// Renames a collection and refreshes the list.
  Future<void> rename(String id, String name) async {
    await CollectionsService.renameCollection(id, name);
    await _refresh();
  }

  /// Deletes a collection (and its artwork) and refreshes the list.
  Future<void> delete(String id) async {
    await CollectionsService.deleteCollection(id);
    await _refresh();
  }

  /// Replaces a collection's artwork with a copy of [pickedFilePath].
  ///
  /// Bumps [imageVersion] on success so widgets keyed on it repaint even though
  /// the file path is unchanged.
  Future<String?> setImage(String id, String pickedFilePath) async {
    final target = await CollectionsService.setCollectionImage(
      id,
      pickedFilePath,
    );
    if (target != null) _imageVersion++;
    await _refresh();
    return target;
  }

  /// Clears a collection's artwork and bumps [imageVersion].
  Future<void> clearImage(String id) async {
    await CollectionsService.clearCollectionImage(id);
    _imageVersion++;
    await _refresh();
  }

  /// Adds [game] to a collection, refreshing the counts.
  Future<void> addGame(String collectionId, GameModel game) async {
    await CollectionsService.addGame(collectionId, game);
    await _refresh();
  }

  /// Removes [game] from a collection, refreshing the counts.
  Future<void> removeGame(String collectionId, GameModel game) async {
    await CollectionsService.removeGame(collectionId, game);
    await _refresh();
  }

  /// Toggles [game]'s membership and returns whether it is now a member.
  Future<bool> toggleGame(String collectionId, GameModel game) async {
    final isMember = await CollectionsService.toggleGame(collectionId, game);
    await _refresh();
    return isMember;
  }

  /// Returns the ids of the collections [game] belongs to.
  ///
  /// Read straight from the database rather than from [collections]: membership
  /// is not held in memory, and the second engine may have changed it.
  Future<Set<String>> collectionIdsFor(GameModel game) =>
      CollectionsService.collectionIdsFor(game);

  /// Re-reads after a mutation, bypassing [load]'s in-flight guard.
  Future<void> _refresh() async {
    _collections = await CollectionsService.getCollections();
    _memberRomPaths = await CollectionsService.memberRomPaths();
    _hasLoaded = true;
    notifyListeners();
  }
}
