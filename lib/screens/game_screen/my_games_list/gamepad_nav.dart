part of '../my_games_list.dart';

/// Gamepad / keyboard input handling for the system games list.
///
/// Registers the [GamepadNavigation] input mappings and implements the
/// navigation-dispatch handlers (D-pad move, details-tab switch, Start). All
/// state lives on the host [State]; this extension only moves the methods out
/// of the monolith — behaviour is unchanged.
extension _GamepadNav on _SystemGamesListState {
  /// Walks the details card one tab (artwork / info / achievements ...).
  ///
  /// Bound to D-pad left/right: the fast alphabet jump on a held up/down made
  /// the old +/-10 page step redundant, so the horizontal axis drives the card
  /// instead. The bumpers are deliberately unbound on this screen.
  ///
  /// Always returns false so a held direction never auto-repeats through the
  /// tabs; the nav sound is played here instead of by the repeat dispatcher.
  bool _switchDetailsTab(bool isRight) {
    if (_tabNavigationAction?.call(isRight) ?? false) {
      SfxService().playNavSound();
    }
    return false;
  }

  /// Handles the A button: steps into the achievements badge grid when the
  /// details card is showing it, and launches the highlighted game otherwise.
  ///
  /// The grid is gated behind A so arriving on the achievements tab never
  /// swallows the D-pad; [_handleBButton] is the matching way back out.
  void _handleAButton() {
    if (_enterAchievementsGrid?.call() ?? false) return;
    _selectCurrentGame();
  }

  /// Handles the B button: leaves the achievements badge grid if it holds the
  /// D-pad, and otherwise backs out of the screen as usual.
  void _handleBButton() {
    if (_exitAchievementsGrid?.call() ?? false) return;
    _goBack();
  }

  /// Handles Select button (View/Share) for mute refresh depending on the
  /// active details tab.
  void _handleSelectButton() {
    SfxService().playNavSound();
    _selectButtonAction?.call();
  }

  /// Handles the X button: opens the game view-mode picker (list/grid/carousel
  /// + card size/style). For the music library, X keeps its shuffle toggle.
  void _handleXButton() {
    if (widget.system.folderName == 'music') {
      final service = MusicPlayerService();
      service.toggleShuffle();
      AppNotification.showNotification(
        context,
        service.isShuffle
            ? AppLocale.shuffleEnabled.getString(context)
            : AppLocale.shuffleDisabled.getString(context),
        type: NotificationType.info,
      );
      return;
    }
    GameViewModeDropdown.globalKey.currentState?.showDropdown();
  }

  /// Registers gamepad and keyboard input mappings for the screen.
  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft, // Previous details tab.
      onNavigateRight: _navigateRight, // Next details tab.
      onLetterJump: _letterJump, // Held D-pad up/down → alphabet skipping.
      accelerateRepeats: true, // Text-only rows keep up with a ramping repeat.
      onSelectItem: _handleAButton, // Button A - RA grid gate, else launch.
      onBack: _handleBButton, // Button B - leave the RA grid, else go back.
      onFavorite: _openGameContextMenu, // Button Y - game context menu.
      onXButton:
          _handleXButton, // Button X - View mode picker (music: shuffle).
      onSettings: _openGameSettingsDialog, // Button Start.
      onSelectButton: _handleSelectButton, // Button Select (View) - tap.
      onSelectModifierA: () => _scrapeAction?.call(), // Select + A - Scrape.
      onSelectModifierY: _showRandomGameDialog, // Select + Y - Random.
      onRightStickClick: null,
      // The bumpers (and their Q/E keyboard twins) bind nothing here: tab
      // switching moved to D-pad left/right.
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'system_games_list',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  /// Moves focus to the previous game in the list.
  void _navigateUp() {
    if (_games.isEmpty) return;

    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementUp?.call();
      return;
    }

    _resetVideoState();
    _updateSelectedGame(
      (_selectedGameIndex - 1 + _games.length) % _games.length,
    );
  }

  /// Moves focus to the next game in the list.
  void _navigateDown() {
    if (_games.isEmpty) return;

    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementDown?.call();
      return;
    }

    _resetVideoState();
    _updateSelectedGame((_selectedGameIndex + 1) % _games.length);
  }

  /// Skips to the neighbouring alphabetical group once up/down has been held
  /// long enough (ES-DE style). Returns false when there is no further letter
  /// in that direction, letting the caller fall back to a normal step so the
  /// selection still wraps at the ends of the list.
  bool _letterJump(bool forward) {
    if (_games.isEmpty) return false;
    if (_isAchievementsOpen != null && _isAchievementsOpen!()) return false;

    final target = LetterJump.targetIndex(
      length: _games.length,
      currentIndex: _selectedGameIndex,
      forward: forward,
      // Every folder row reports the same sentinel group, so a held jump
      // steps over the folders as one block instead of treating each folder
      // name's initial as its own alphabet boundary.
      letterAt: (index) => index < _folderCount
          ? _SystemGamesListState._folderJumpGroup
          : LetterJump.letterFor(_games[index]),
    );
    if (target == null) return false;

    _updateSelectedGame(target, forceFast: true);
    return true;
  }

  /// Switches to the previous details tab, or moves within the achievements
  /// overlay while it owns the input.
  bool _navigateLeft() {
    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementLeft?.call();
      return true;
    }

    return _switchDetailsTab(false);
  }

  /// Switches to the next details tab, or moves within the achievements
  /// overlay while it owns the input.
  bool _navigateRight() {
    if (_isAchievementsOpen != null && _isAchievementsOpen!()) {
      _moveAchievementRight?.call();
      return true;
    }

    return _switchDetailsTab(true);
  }
}
