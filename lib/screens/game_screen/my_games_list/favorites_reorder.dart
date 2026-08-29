part of '../my_games_list.dart';

/// Favorite toggling and list re-ordering for the system games list.
///
/// A favourite toggle re-sorts the loaded list favourites-first, so the press
/// has a visible result instead of one that only shows up the next time the
/// system is opened. A re-scrape re-sorts too, because a renamed game's
/// alphabetical rank really did change. The re-scrape follows the *game* to
/// its new rank; the favourite toggle leaves the cursor on the row the user
/// was looking at.
///
/// All state lives on the host [State]; this extension only holds the methods
/// that read and write it. The `setState` calls route through the host
/// [rebuild] bridge (`State.setState` is `@protected` and can't be invoked
/// from an extension).
extension _FavoritesReorder on _SystemGamesListState {
  /// Toggles the 'favorite' status for the selected game.
  Future<void> _toggleFavorite() async {
    if (_selectedGame == null) return;
    if (_isFolderEntry(_selectedGame)) return;

    if (widget.system.folderName == 'music') {
      try {
        final configProvider = context.read<SqliteConfigProvider>();
        await GameService.toggleFavorite(_selectedGame!);
        if (!mounted) return;
        await configProvider.refreshDetectedSystems();

        _applyFavoriteToLoadedList();
      } catch (e) {
        _SystemGamesListState._log.e('Error toggling music favorite: $e');
      }
      return;
    }

    try {
      final configProvider = context.read<SqliteConfigProvider>();
      await GameService.toggleFavorite(_selectedGame!);

      if (!mounted) return;
      await configProvider.refreshDetectedSystems();

      _applyFavoriteToLoadedList();
    } catch (error) {
      if (!mounted) return;
      _SystemGamesListState._log.e('Error toggling favorite: $error');
      if (!mounted) return;
      AppNotification.showNotification(
        context,
        AppLocale.errorUpdatingFavorite.getString(context),
        type: NotificationType.error,
      );
    }
  }

  /// Mirrors a favourite change into the list already on screen and moves the
  /// game to where reopening the system would seat it.
  ///
  /// Favourites-first is the *load* order — the query behind
  /// [GameService.loadGamesForSystem] sorts `is_favorite DESC` before
  /// `LOWER(game_display_name)` — and [_byFavouriteThenName] anticipates it
  /// here so the press has a visible result rather than one that only appears
  /// the next time the system is opened.
  ///
  /// **The cursor holds its place on screen; it does not follow the game.**
  /// The highlight stays on the row the user was looking at, so the list never
  /// moves out from under it. The trade is that a game jumping to the top
  /// leaves the selection on whichever game slid up into the slot it vacated:
  /// the reorder is the confirmation that the press registered, and the cursor
  /// staying put is what keeps the press from relocating the user.
  ///
  /// The sort lands on [_allGames], not on the visible list, because in
  /// subfolder view the visible list is *derived* from it — sorting the
  /// derived copy would be undone by the next rebuild, and the flag itself
  /// would be lost with it. Both are published as new lists rather than
  /// written into: the grid and carousel key their cached artwork cards off
  /// the list identity.
  void _applyFavoriteToLoadedList() {
    final selected = _selectedGame;
    if (selected == null) return;

    final index = _allGames.indexWhere(
      (game) => game.romname == selected.romname,
    );
    if (index == -1) return;

    // The slot to hold the cursor on, read from the visible list because that
    // is the one the highlight indexes into.
    final anchorIndex = _games.indexWhere(
      (game) => game.romname == selected.romname,
    );

    final updated = _allGames[index].copyWith(
      isFavorite: !(_allGames[index].isFavorite ?? false),
    );

    rebuild(() {
      _allGames = replaceGameInList(_allGames, updated)
        ..sort(_byFavouriteThenName);
      _games = _buildDisplayList();
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      if (anchorIndex != -1 && anchorIndex < _games.length) {
        _selectedGameIndex = anchorIndex;
        _selectedGame = _games[anchorIndex];
      }
    });
  }

  /// Sorts the list and re-anchors focus to a specific ROM.
  /// Primarily used after scraping to follow a game to its new alphabetical position.
  void _reorderGamesListFollowingGame(String romname) {
    if (_subfolderViewEnabled) {
      rebuild(() {
        _games = _buildDisplayList();
        _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};
        final newIndex = _games.indexWhere((g) => g.romname == romname);
        if (newIndex != -1) {
          _selectedGameIndex = newIndex;
          _selectedGame = _games[newIndex];
        } else if (_games.isNotEmpty) {
          _selectedGameIndex = 0;
          _selectedGame = _games.first;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToSelectedItem();
      });
      return;
    }

    rebuild(() {
      _games = List<GameModel>.from(_games)..sort(_byFavouriteThenName);
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};

      final newIndex = _games.indexWhere((g) => g.romname == romname);
      if (newIndex != -1) {
        _selectedGameIndex = newIndex;
        _selectedGame = _games[newIndex];
      } else if (_games.isNotEmpty) {
        _selectedGameIndex = 0;
        _selectedGame = _games.first;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToSelectedItem();
    });
  }
}

/// The order the list loads in: favourites first, then display name folded to
/// lower case, exactly as `ORDER BY ur.is_favorite DESC,
/// LOWER(game_display_name) ASC` does it.
///
/// Any in-memory re-sort is anticipating that query, so it has to agree with
/// it. The favourites-first comparator this replaces compared names
/// case-sensitively, which could seat a game somewhere a reload would not.
int _byFavouriteThenName(GameModel a, GameModel b) {
  final bool aFavourite = a.isFavorite == true;
  final bool bFavourite = b.isFavorite == true;
  if (aFavourite != bFavourite) return aFavourite ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
