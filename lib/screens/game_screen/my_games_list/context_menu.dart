part of '../my_games_list.dart';

/// The Y-button game context menu for the system games list.
///
/// Y used to toggle the favourite directly; it now opens an anchored menu that
/// starts on `Settings`, with the favourite one submenu away under `Add to…` /
/// `Remove from…`. With the vertical action rail gone this menu is also the
/// only route to the view-level actions (view mode, random) for a user without
/// a gamepad, so it carries those below a separator — and a long-press on a row
/// opens it, which is what [_openGameContextMenuFor] is for.
extension _ContextMenu on _SystemGamesListState {
  /// Long-press entry point: selects [game] first so the menu anchors to its
  /// row, then opens the menu once that row has been laid out with the anchor
  /// key attached (the key follows the *selected* row, so opening in the same
  /// frame would anchor to whichever row was selected before the press).
  Future<void> _openGameContextMenuFor(GameModel game) async {
    if (!identical(game, _selectedGame)) {
      await _selectGame(game);
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    await _openGameContextMenu();
  }

  /// Opens the context menu for the selected game.
  ///
  /// Music keeps Y = favourite (the music library has its own toggle branch),
  /// and folder rows have no memberships at all, so both bail out before the
  /// menu is built — mirroring [_toggleFavorite]'s guards.
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
      onSettings: _openGameSettingsDialog,
      onCreateTarget: () => _createCollectionFromMenu(game),
      createTargetLabel: AppLocale.newCollection.getString(context),
      onViewMode: () =>
          GameViewModeDropdown.globalKey.currentState?.showDropdown(),
      onRandom: _showRandomGameDialog,
    );
  }

  /// Applies a favourite change chosen in the menu and reports it.
  ///
  /// [_toggleFavorite] already owns the full follow-up (refreshDetectedSystems
  /// so the Favourites system card appears/disappears, and the local
  /// `copyWith(isFavorite:)`), so the menu adds the toast and — exactly like
  /// [_setCollectionMembershipFromMenu] — the reload that lets an unfavourited
  /// game leave the Favourites view it was removed from.
  Future<void> _setFavoriteFromMenu(bool adding, String label) async {
    await _toggleFavorite();
    if (!mounted) return;

    // Viewing Favourites and the game just left it: the toggle above only
    // updates the flag on the row already loaded, so without this the row
    // stays visible until the list is rebuilt. (In this view every game is a
    // favourite, so only removal can happen here.)
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
        AppLocale.errorUpdatingCollection.getString(context),
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
        AppLocale.errorUpdatingCollection.getString(context),
        type: NotificationType.error,
      );
    }
  }
}

/// Identifier of the Favourites bucket inside the context menu. Collections
/// use `collection:<uuid>`, so the two never collide.
const String _favoritesTargetId = 'favorites';
