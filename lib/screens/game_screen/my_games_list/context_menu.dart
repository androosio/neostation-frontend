part of '../my_games_list.dart';

/// The Y-button game context menu for the system games list.
///
/// Y used to toggle the favourite directly; it now opens an anchored menu whose
/// Favourites entry is pre-highlighted, so the old one-press action survives as
/// `Y, A`. The one-press toggle is still on the details-card / side-legend Y
/// action button, which keeps calling [_toggleFavorite] directly.
extension _ContextMenu on _SystemGamesListState {
  /// Opens the context menu for the selected game.
  ///
  /// Music keeps Y = favourite (the music library has its own toggle branch and
  /// reorder behaviour), and folder rows have no memberships at all, so both
  /// bail out before the menu is built — mirroring [_toggleFavorite]'s guards.
  Future<void> _openGameContextMenu() async {
    final game = _selectedGame;
    if (game == null) return;
    if (_isFolderEntry(game)) return;
    if (widget.system.folderName == 'music') {
      await _toggleFavorite();
      return;
    }

    SfxService().playNavSound();

    final collectionsProvider = context.read<CollectionsProvider>();

    // Membership is never held in memory (the second engine may have changed
    // it), so resolve it before the menu is built — the menu must not resize
    // under the cursor.
    final memberIds = await collectionsProvider.collectionIdsFor(game);
    if (!mounted) return;

    final favouritesLabel = AppLocale.favorite.getString(context);

    final targets = <GameContextMenuTarget>[
      GameContextMenuTarget(
        id: _favoritesTargetId,
        label: favouritesLabel,
        icon: Symbols.favorite_rounded,
        isMember: game.isFavorite == true,
        add: () => _setFavoriteFromMenu(true, favouritesLabel),
        remove: () => _setFavoriteFromMenu(false, favouritesLabel),
      ),
      for (final collection in collectionsProvider.collections)
        GameContextMenuTarget(
          id: '${SystemFolderNames.collectionPrefix}${collection.id}',
          label: collection.name,
          icon: Symbols.bookmark_rounded,
          isMember: memberIds.contains(collection.id),
          add: () => _setCollectionMembershipFromMenu(
            collection.id,
            collection.name,
            adding: true,
          ),
          remove: () => _setCollectionMembershipFromMenu(
            collection.id,
            collection.name,
            adding: false,
          ),
        ),
    ];

    await showGameContextMenu(
      context: context,
      targets: targets,
      anchorKey: _selectedItemKey,
      // Pre-highlight Favourites, whichever submenu it landed in.
      preselectTargetId: _favoritesTargetId,
      onSettings: _openGameSettingsDialog,
      onCreateTarget: () => _createCollectionFromMenu(game),
      createTargetLabel: AppLocale.newCollection.getString(context),
    );
  }

  /// Applies a favourite change chosen in the menu and reports it.
  ///
  /// [_toggleFavorite] already owns the full follow-up (refreshDetectedSystems
  /// so the Favourites system card appears/disappears, the local
  /// `copyWith(isFavorite:)` and the visual-position-preserving re-sort), so
  /// the menu adds the toast and — exactly like
  /// [_setCollectionMembershipFromMenu] — the reload that lets an unfavourited
  /// game leave the Favourites view it was removed from.
  Future<void> _setFavoriteFromMenu(bool adding, String label) async {
    await _toggleFavorite();
    if (!mounted) return;

    // Viewing Favourites and the game just left it: the re-sort above only
    // reorders what is already loaded, so without this the row stays visible
    // until the list is rebuilt. (In this view every game is a favourite, so
    // only removal can happen here.)
    if (!adding && widget.system.folderName == SystemFolderNames.favorites) {
      await _loadGames();
      if (!mounted) return;
    }

    AppNotification.showNotification(
      context,
      (adding ? AppLocale.addedToCollection : AppLocale.removedFromCollection)
          .getString(context)
          .replaceFirst('{name}', label),
      type: NotificationType.success,
    );
  }

  /// Adds or removes the selected game from [collectionId] and reports it.
  ///
  /// When the list currently being shown *is* that collection, the removed game
  /// has to leave the view too, so the list is reloaded.
  Future<void> _setCollectionMembershipFromMenu(
    String collectionId,
    String label, {
    required bool adding,
  }) async {
    final game = _selectedGame;
    if (game == null) return;

    final provider = context.read<CollectionsProvider>();
    try {
      if (adding) {
        await provider.addGame(collectionId, game);
      } else {
        await provider.removeGame(collectionId, game);
      }
    } catch (e) {
      _SystemGamesListState._log.e('Collection membership change failed: $e');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingFavorite.getString(context),
        type: NotificationType.error,
      );
      return;
    }

    if (!mounted) return;

    // Viewing the collection we just changed: the list itself is now stale.
    if (widget.system.folderName ==
        '${SystemFolderNames.collectionPrefix}$collectionId') {
      await _loadGames();
      if (!mounted) return;
    }

    AppNotification.showNotification(
      context,
      (adding ? AppLocale.addedToCollection : AppLocale.removedFromCollection)
          .getString(context)
          .replaceFirst('{name}', label),
      type: NotificationType.success,
    );
  }

  /// Creates a collection from the `New collection…` row and puts [game] in it.
  ///
  /// The name is generated rather than typed: on-screen text entry arrives with
  /// the collections browser screen, which also owns renaming. The counter
  /// walks past names already in use so repeated creates never collide.
  Future<void> _createCollectionFromMenu(GameModel game) async {
    final provider = context.read<CollectionsProvider>();
    final existing = provider.collections.map((c) => c.name).toSet();
    final template = AppLocale.newCollectionDefaultName.getString(context);

    var index = provider.collections.length + 1;
    var name = template.replaceFirst('{number}', '$index');
    while (existing.contains(name)) {
      index++;
      name = template.replaceFirst('{number}', '$index');
    }

    try {
      final created = await provider.create(name);
      await provider.addGame(created.id, game);
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.addedToCollection
            .getString(context)
            .replaceFirst('{name}', created.name),
        type: NotificationType.success,
      );
    } catch (e) {
      _SystemGamesListState._log.e('Collection creation failed: $e');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingFavorite.getString(context),
        type: NotificationType.error,
      );
    }
  }
}

/// Identifier of the Favourites bucket inside the context menu. Collections
/// use `collection:<uuid>`, so the two never collide.
const String _favoritesTargetId = 'favorites';
