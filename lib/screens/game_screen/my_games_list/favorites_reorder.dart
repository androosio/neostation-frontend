part of '../my_games_list.dart';

/// Favorite toggling and list re-ordering for the system games list.
///
/// A favourite toggle updates the flag in place and leaves the row where it
/// is; favourites-first ordering is applied when the list is loaded. A
/// re-scrape does re-sort, because a renamed game's alphabetical rank really
/// did change — and that one follows the game rather than the index.
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

  /// Mirrors a favourite change into the list already on screen, without
  /// re-sorting it.
  ///
  /// Favourites-first is the *load* order (the query behind
  /// [GameService.loadGamesForSystem] sorts `is_favorite DESC` before the
  /// name), so a newly favourited game does take its place at the front the
  /// next time the system is opened. Re-sorting here instead made the row leap
  /// to the top the instant the button was pressed, and because the cursor
  /// stayed on the *index* rather than the game, the selection was left on
  /// whatever game slid into the vacated slot.
  ///
  /// Publishes a new list rather than writing into the current one: the grid
  /// and carousel key their cached artwork cards off the list identity, which
  /// the re-sort this replaces used to change as a side effect.
  void _applyFavoriteToLoadedList() {
    final selected = _selectedGame;
    if (selected == null) return;

    final index = _games.indexWhere((game) => game.romname == selected.romname);
    if (index == -1) return;

    final updated = _games[index].copyWith(
      isFavorite: !(_games[index].isFavorite ?? false),
    );

    rebuild(() {
      _games = replaceGameInList(_games, updated);
      _gameIndexMap = {for (int i = 0; i < _games.length; i++) _games[i]: i};
      _selectedGameIndex = index;
      _selectedGame = updated;
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
      final sortedGames = List<GameModel>.from(_games);
      sortedGames.sort((a, b) {
        if (a.isFavorite == true && b.isFavorite != true) return -1;
        if (a.isFavorite != true && b.isFavorite == true) return 1;
        return a.name.compareTo(b.name);
      });
      _games = sortedGames;
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
