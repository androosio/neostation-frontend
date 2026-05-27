import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/game_utils.dart';
import 'package:neostation/widgets/game_view_mode_dropdown.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';

class GamesGrid extends StatefulWidget {
  final SystemModel system;
  final List<GameModel> games;
  final int selectedIndex;
  final FileProvider fileProvider;
  final Function(GameModel) onGameSelected;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final VoidCallback onRandom;
  final VoidCallback? onSettings;
  final VoidCallback? onScrape;

  const GamesGrid({
    super.key,
    required this.system,
    required this.games,
    required this.selectedIndex,
    required this.fileProvider,
    required this.onGameSelected,
    required this.onBack,
    required this.onPlay,
    required this.onFavorite,
    required this.onRandom,
    this.onSettings,
    this.onScrape,
  });

  @override
  State<GamesGrid> createState() => _GamesGridState();
}

class _GamesGridState extends State<GamesGrid> {
  late GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();
  int _selectedIndex = 0;
  int _crossAxisCount = 5;
  bool _isNavigatingFast = false;
  DateTime? _lastNavTime;
  static const Duration _fastNavThreshold = Duration(milliseconds: 150);

  static const double _spX = 14; // horizontal spacing
  static const double _spY = 18; // vertical spacing
  static const double _cardAspect = 1.0 / 1.5;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedIndex.clamp(
      0,
      (widget.games.length - 1).clamp(0, 999999),
    );
    _updateCrossAxisCount();
    _initializeGamepad();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _gamepadNav.initialize();
        GamepadNavigationManager.pushLayer(
          'games_grid',
          onActivate: () => _gamepadNav.activate(),
          onDeactivate: () => _gamepadNav.deactivate(),
        );
        _ensureSelectedVisible();
      }
    });
  }

  void _updateCrossAxisCount() {
    try {
      final config = context.read<SqliteConfigProvider>().config;
      switch (config.systemGridColumns) {
        case 'S':
          _crossAxisCount = 4;
          break;
        case 'M':
          _crossAxisCount = 5;
          break;
        case 'L':
          _crossAxisCount = 6;
          break;
        case 'XL':
          _crossAxisCount = 7;
          break;
        default:
          _crossAxisCount = 5;
      }
    } catch (_) {
      _crossAxisCount = 5;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCrossAxisCount();
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: widget.onPlay,
      onBack: widget.onBack,
      onFavorite: widget.onFavorite,
      onXButton: () {
        try {
          GameViewModeDropdown.globalKey.currentState?.showDropdown();
        } catch (_) {}
      },
      onLeftTrigger: widget.onRandom,
      onSelectButton: widget.onScrape,
      onSettings: widget.onSettings,
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('games_grid');
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  int get _cols => _crossAxisCount.clamp(1, 10);

  void _navigateUp() {
    if (widget.games.isEmpty) return;
    final c = _cols;
    setState(() {
      int ni = _selectedIndex - c;
      if (ni < 0) {
        final col = _selectedIndex % c;
        final rows = (widget.games.length / c).ceil();
        ni = (rows - 1) * c + col;
        if (ni >= widget.games.length) ni -= c;
        if (ni < 0) ni = _selectedIndex;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _navigateDown() {
    if (widget.games.isEmpty) return;
    final c = _cols;
    setState(() {
      int ni = _selectedIndex + c;
      if (ni >= widget.games.length) ni = _selectedIndex % c;
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _navigateLeft() {
    if (widget.games.isEmpty) return;
    setState(() {
      int ni;
      if (_selectedIndex % _cols == 0) {
        ni = (_selectedIndex ~/ _cols) * _cols + (_cols - 1);
        if (ni >= widget.games.length) ni = widget.games.length - 1;
      } else {
        ni = _selectedIndex - 1;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _navigateRight() {
    if (widget.games.isEmpty) return;
    setState(() {
      int ni;
      if ((_selectedIndex + 1) % _cols == 0 ||
          _selectedIndex == widget.games.length - 1) {
        ni = (_selectedIndex ~/ _cols) * _cols;
      } else {
        ni = _selectedIndex + 1;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _updateFastNav() {
    final now = DateTime.now();
    if (_lastNavTime != null &&
        now.difference(_lastNavTime!) < _fastNavThreshold) {
      _isNavigatingFast = true;
    } else {
      _isNavigatingFast = false;
    }
    _lastNavTime = now;
  }

  void _onSelectionChanged() {
    if (_selectedIndex < widget.games.length) {
      widget.onGameSelected(widget.games[_selectedIndex]);
    }
  }

  void _ensureSelectedVisible() {
    if (!_scrollController.hasClients) return;
    final row = _selectedIndex ~/ _cols;
    final screenHeight = MediaQuery.of(context).size.height;
    final availableWidth = MediaQuery.of(context).size.width - 16;
    final cardWidth = (availableWidth - (_cols - 1) * _spX) / _cols;
    final cardHeight = cardWidth / _cardAspect;
    final rowHeight = cardHeight + _spY;
    final viewportHeight = screenHeight - 120;

    final targetOffset = (row * rowHeight - viewportHeight / 2 + rowHeight / 2)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    final duration = _isNavigatingFast
        ? const Duration(milliseconds: 80)
        : const Duration(milliseconds: 200);

    _scrollController.animateTo(
      targetOffset,
      duration: duration,
      curve: _isNavigatingFast ? Curves.linear : Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.games.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videogame_asset_rounded,
              size: 64.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            SizedBox(height: 16.r),
            Text(
              AppLocale.selectAGame.getString(context),
              style: TextStyle(
                fontSize: 18.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildGridHeader(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth - 16;
              final cardWidth = (totalWidth - (_cols - 1) * _spX) / _cols;
              final cardHeight = cardWidth / _cardAspect;
              final rowHeight = cardHeight + _spY;
              final totalRows = (widget.games.length / _cols).ceil();
              final contentHeight = totalRows * rowHeight + 80;

              // Build highlight info
              final selRow = _selectedIndex ~/ _cols;
              final selCol = _selectedIndex % _cols;
              final hlLeft = selCol * (cardWidth + _spX);
              final hlTop = selRow * rowHeight;
              final hlDuration = Duration(
                milliseconds: _isNavigatingFast ? 120 : 280,
              );

              return SingleChildScrollView(
                controller: _scrollController,
                padding: EdgeInsets.only(top: 4, bottom: 80, left: 8, right: 8),
                child: SizedBox(
                  height: contentHeight,
                  child: Stack(
                    children: [
                      // Cards
                      for (int i = 0; i < widget.games.length; i++)
                        _buildCard(i, cardWidth, cardHeight, rowHeight),
                      // Highlight overlay
                      AnimatedPositioned(
                        duration: hlDuration,
                        curve: Curves.easeOutQuart,
                        left: hlLeft,
                        top: hlTop,
                        width: cardWidth,
                        height: cardHeight,
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                  width: 2.6.r,
                                ),
                                borderRadius: BorderRadius.circular(6.r),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCard(
    int index,
    double cardWidth,
    double cardHeight,
    double rowHeight,
  ) {
    final game = widget.games[index];
    final col = index % _cols;
    final row = index ~/ _cols;
    final left = col * (cardWidth + _spX);
    final top = row * rowHeight;
    final box2dPath = game.getImagePath(
      widget.system.primaryFolderName,
      'box2d',
      widget.fileProvider,
    );
    final hasBox2d = File(box2dPath).existsSync();

    return Positioned(
      left: left,
      top: top,
      width: cardWidth,
      height: cardHeight,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedIndex = index);
          widget.onGameSelected(game);
          SfxService().playNavSound();
        },
        child: RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.25),
                width: 1.r,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: hasBox2d
                ? Image.file(
                    File(box2dPath),
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    isAntiAlias: true,
                    errorBuilder: (context, error, stackTrace) =>
                        _buildPlaceholder(game),
                  )
                : _buildPlaceholder(game),
          ),
        ),
      ),
    );
  }

  Widget _buildGridHeader() {
    final dropdownState = GameViewModeDropdown.globalKey.currentState;
    final viewModeKey = GlobalKey();

    final shortName =
        (widget.system.shortName != null && widget.system.shortName!.isNotEmpty)
        ? widget.system.shortName!
        : widget.system.realName;

    final selectedGame = _selectedIndex < widget.games.length
        ? widget.games[_selectedIndex]
        : null;
    final selectedName = selectedGame != null
        ? GameUtils.formatGameName(
            selectedGame.name.isNotEmpty
                ? selectedGame.name
                : selectedGame.romname,
          )
        : '';

    return Container(
      margin: EdgeInsets.only(left: 8.r, right: 8.r, top: 8.r, bottom: 4.r),
      child: Row(
        children: [
          _buildIconButton(
            iconPath: 'assets/images/gamepad/Xbox_B_button.png',
            symbol: Symbols.arrow_back_rounded,
            color: Theme.of(context).colorScheme.error,
            onTap: widget.onBack,
          ),
          SizedBox(width: 6.r),
          _buildIconButton(
            key: viewModeKey,
            iconPath: 'assets/images/gamepad/Xbox_X_button.png',
            symbol: Symbols.grid_view_rounded,
            color: Theme.of(context).colorScheme.primary,
            onTap: () {
              SfxService().playNavSound();
              dropdownState?.showDropdownFrom(viewModeKey);
            },
          ),
          SizedBox(width: 6.r),
          _buildIconButton(
            iconPath: 'assets/images/gamepad/Left Stick Click.png',
            symbol: Symbols.casino_rounded,
            color: Theme.of(context).colorScheme.tertiary,
            onTap: widget.onRandom,
          ),
          SizedBox(width: 10.r),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.4),
                width: 1.r,
              ),
            ),
            child: Text(
              shortName,
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 0.5.r,
              ),
            ),
          ),
          if (selectedName.isNotEmpty) ...[
            SizedBox(width: 10.r),
            Expanded(
              child: Text(
                selectedName,
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIconButton({
    Key? key,
    required String iconPath,
    required IconData symbol,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(6.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6.r),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 2.r,
                offset: Offset(1.r, 1.r),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                iconPath,
                width: 16.r,
                height: 16.r,
                color: Colors.white,
                colorBlendMode: BlendMode.srcIn,
              ),
              SizedBox(width: 4.r),
              Icon(symbol, size: 16.r, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(GameModel game) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videogame_asset_rounded,
              size: 32.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            SizedBox(height: 4.r),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.r),
              child: Text(
                GameUtils.formatGameName(
                  game.name.isNotEmpty ? game.name : game.romname,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 7.r,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
