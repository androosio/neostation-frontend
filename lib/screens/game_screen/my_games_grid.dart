import 'dart:io';
import 'dart:typed_data';
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
import 'package:neostation/repositories/game_repository.dart';
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

  static const double _spX = 12;
  static const double _spY = 14;

  // Layout
  List<_CardRect> _cardRects = [];
  double _contentHeight = 0;
  double _cardWidth = 0;
  double? _lastLayoutWidth;
  int? _lastLayoutCols;
  int? _lastLayoutGameCount;

  // Image dimension cache
  static final Map<String, Size?> _imageSizeCache = {};

  // Visible index tracking for lazy dimension loading
  final Set<int> _loadedDims = {};

  // ---- Image size reading ----
  static Size? _readImageSize(String path) {
    if (_imageSizeCache.containsKey(path)) return _imageSizeCache[path];
    try {
      final file = File(path);
      if (!file.existsSync()) {
        _imageSizeCache[path] = null;
        return null;
      }
      final raf = file.openSync();
      try {
        final header = Uint8List(24);
        raf.readIntoSync(header);
        if (header[0] == 0x89 &&
            header[1] == 0x50 &&
            header[2] == 0x4E &&
            header[3] == 0x47) {
          final w = _readInt32BE(header, 16);
          final h = _readInt32BE(header, 20);
          if (w > 0 && h > 0 && w < 10000 && h < 10000) {
            final r = Size(w.toDouble(), h.toDouble());
            _imageSizeCache[path] = r;
            return r;
          }
        }
        if (header[0] == 0xFF && header[1] == 0xD8) {
          raf.setPositionSync(0);
          final len = (raf.lengthSync()).clamp(0, 65536).toInt();
          final buf = Uint8List(len);
          raf.readIntoSync(buf);
          int i = 2;
          while (i < buf.length - 9) {
            if (buf[i] != 0xFF) {
              i++;
              continue;
            }
            if (buf[i + 1] == 0xC0 || buf[i + 1] == 0xC2) {
              final h = (buf[i + 5] << 8) | buf[i + 6];
              final w = (buf[i + 7] << 8) | buf[i + 8];
              if (w > 0 && h > 0 && w < 10000 && h < 10000) {
                final r = Size(w.toDouble(), h.toDouble());
                _imageSizeCache[path] = r;
                return r;
              }
            }
            i += ((buf[i + 2] << 8) | buf[i + 3]) + 2;
          }
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
    _imageSizeCache[path] = null;
    return null;
  }

  static int _readInt32BE(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  String _box2dPath(int index) => widget.games[index].getImagePath(
    widget.system.primaryFolderName,
    'box2d',
    widget.fileProvider,
  );

  double _cardHeightFor(int index) {
    final game = widget.games[index];
    // 1. From DB
    if (game.box2dAspectRatio != null && game.box2dAspectRatio!.isNotEmpty) {
      final parts = game.box2dAspectRatio!.split('/');
      if (parts.length == 2) {
        final w = double.tryParse(parts[0]);
        final h = double.tryParse(parts[1]);
        if (w != null && h != null && w > 0 && h > 0) {
          return _cardWidth / (w / h);
        }
      }
    }
    // 2. From file header
    final path = _box2dPath(index);
    final size = _readImageSize(path);
    if (size != null && size.width > 0 && size.height > 0) {
      // Save to DB for next time
      final ratio = '${size.width.toInt()}/${size.height.toInt()}';
      _scheduleAspectRatioSave(game, ratio);
      return _cardWidth / (size.width / size.height);
    }
    return _cardWidth; // 1:1 fallback
  }

  final Set<String> _pendingSaves = {};
  void _scheduleAspectRatioSave(GameModel game, String ratio) {
    final key = '${game.systemId}_${game.romname}';
    if (_pendingSaves.contains(key)) return;
    _pendingSaves.add(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingSaves.remove(key);
      if (game.systemId != null) {
        GameRepository.updateBox2dAspectRatio(
          game.systemId!,
          game.romname,
          ratio,
        );
      }
    });
  }

  // ---- Layout (computed once, cached) ----
  bool _needsLayout(double w) =>
      _lastLayoutWidth != w ||
      _lastLayoutCols != _cols ||
      _lastLayoutGameCount != widget.games.length;

  void _computeLayout(double availableWidth) {
    if (!_needsLayout(availableWidth)) return;
    _lastLayoutWidth = availableWidth;
    _lastLayoutCols = _cols;
    _lastLayoutGameCount = widget.games.length;

    final totalWidth = availableWidth - 16;
    _cardWidth = (totalWidth - (_cols - 1) * _spX) / _cols;
    final n = widget.games.length;
    _cardRects = List.generate(
      n,
      (_) => _CardRect(left: 0, top: 0, width: _cardWidth, height: _cardWidth),
    ); // placeholder
    _loadedDims.clear();

    // First pass: use the static cache to get known dimensions fast
    double y = 0;
    int i = 0;
    while (i < n) {
      double maxH = 0;
      final end = (i + _cols).clamp(0, n);
      for (int idx = i; idx < end; idx++) {
        final h = _cardHeightFor(idx);
        if (h > maxH) maxH = h;
      }
      for (int idx = i; idx < end; idx++) {
        final col = idx % _cols;
        final h = _cardHeightFor(idx);
        _cardRects[idx] = _CardRect(
          left: col * (_cardWidth + _spX),
          top: y + (maxH - h) / 2,
          width: _cardWidth,
          height: h,
        );
        if (_imageSizeCache.containsKey(_box2dPath(idx))) _loadedDims.add(idx);
      }
      y += maxH + _spY;
      i = end;
    }
    _contentHeight = y + 80;
  }

  // Lazy dimension loading for newly visible cards
  void _ensureDims(int index) {
    if (_loadedDims.contains(index)) return;
    final path = _box2dPath(index);
    _readImageSize(path); // touches cache, fills in dimension
    _loadedDims.add(index);
  }

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedIndex.clamp(
      0,
      (widget.games.length - 1).clamp(0, 999999),
    );
    _updateCrossAxisCount();
    _initializeGamepad();
    _scrollController.addListener(_onScroll);

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

  void _onScroll() => setState(() {});

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
    _scrollController.removeListener(_onScroll);
    GamepadNavigationManager.popLayer('games_grid');
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  int get _cols => _crossAxisCount.clamp(1, 10);

  void _navigateUp() {
    _navDelta(-_cols);
  }

  void _navigateDown() {
    _navDelta(_cols);
  }

  void _navigateLeft() {
    _navHoriz(-1);
  }

  void _navigateRight() {
    _navHoriz(1);
  }

  void _navDelta(int delta) {
    if (widget.games.isEmpty) return;
    final c = _cols;
    setState(() {
      int ni = _selectedIndex + delta;
      if (delta < 0 && ni < 0) {
        final col = _selectedIndex % c;
        ni = ((widget.games.length / c).ceil() - 1) * c + col;
        while (ni >= widget.games.length) {
          ni -= c;
        }
        if (ni < 0) ni = _selectedIndex;
      } else if (delta > 0 && ni >= widget.games.length) {
        ni = _selectedIndex % c;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _navHoriz(int dir) {
    if (widget.games.isEmpty) return;
    setState(() {
      int ni;
      if (dir < 0) {
        final wrapRight = (_selectedIndex ~/ _cols) * _cols + _cols - 1;
        ni = _selectedIndex % _cols == 0
            ? (wrapRight < widget.games.length - 1
                  ? wrapRight
                  : widget.games.length - 1)
            : _selectedIndex - 1;
      } else {
        final next = _selectedIndex + 1;
        ni = (next % _cols == 0 || next >= widget.games.length)
            ? (_selectedIndex ~/ _cols) * _cols
            : next;
      }
      _selectedIndex = ni.clamp(0, widget.games.length - 1);
      _updateFastNav();
    });
    _ensureSelectedVisible();
    _onSelectionChanged();
    SfxService().playNavSound();
  }

  void _onSelectionChanged() {
    if (_selectedIndex < widget.games.length)
      widget.onGameSelected(widget.games[_selectedIndex]);
  }

  void _updateFastNav() {
    final now = DateTime.now();
    _isNavigatingFast =
        _lastNavTime != null &&
        now.difference(_lastNavTime!) < _fastNavThreshold;
    _lastNavTime = now;
  }

  void _ensureSelectedVisible() {
    if (!_scrollController.hasClients || _cardRects.isEmpty) return;
    final rect = _cardRects[_selectedIndex.clamp(0, _cardRects.length - 1)];
    final screenHeight = MediaQuery.of(context).size.height;
    final viewportH = screenHeight - 120;
    final target = (rect.top - viewportH / 2 + rect.height / 2).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: Duration(milliseconds: _isNavigatingFast ? 80 : 200),
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
              _computeLayout(constraints.maxWidth);

              final selRect = _selectedIndex < _cardRects.length
                  ? _cardRects[_selectedIndex]
                  : _cardRects.first;
              final hlDuration = Duration(
                milliseconds: _isNavigatingFast ? 120 : 280,
              );
              final theme = Theme.of(context);
              final systemFolder = widget.system.primaryFolderName;
              final fp = widget.fileProvider;
              final targetWidth = (_cardWidth * 1.5).toInt();
              final viewportH = constraints.maxHeight;
              final startY = _scrollController.hasClients
                  ? _scrollController.offset - 300
                  : 0.0;
              final endY = startY + viewportH + 600;

              final visibleCards = <Widget>[];
              for (int i = 0; i < _cardRects.length; i++) {
                final r = _cardRects[i];
                if (r.top + r.height >= startY && r.top <= endY) {
                  _ensureDims(i);
                  visibleCards.add(
                    _buildCard(i, r, systemFolder, fp, targetWidth, theme),
                  );
                }
              }

              return SingleChildScrollView(
                controller: _scrollController,
                padding: EdgeInsets.only(top: 4, bottom: 80, left: 8, right: 8),
                child: SizedBox(
                  height: _contentHeight,
                  child: Stack(
                    children: [
                      ...visibleCards,
                      AnimatedPositioned(
                        duration: hlDuration,
                        curve: Curves.easeOutQuart,
                        left: selRect.left,
                        top: selRect.top,
                        width: selRect.width,
                        height: selRect.height,
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: theme.colorScheme.secondary,
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
    _CardRect rect,
    String systemFolder,
    FileProvider fp,
    int targetWidth,
    ThemeData theme,
  ) {
    final game = widget.games[index];
    final box2dPath = game.getImagePath(systemFolder, 'box2d', fp);

    return Positioned(
      key: ValueKey('card_${game.romname}'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
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
                color: theme.colorScheme.outline.withValues(alpha: 0.25),
                width: 1.r,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: _GameCardImage(
              key: ValueKey('img_${game.romname}'),
              box2dPath: box2dPath,
              game: game,
              targetWidth: targetWidth,
            ),
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
    final selGame = _selectedIndex < widget.games.length
        ? widget.games[_selectedIndex]
        : null;
    final selName = selGame != null
        ? GameUtils.formatGameName(
            selGame.name.isNotEmpty ? selGame.name : selGame.romname,
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
          if (selName.isNotEmpty) ...[
            SizedBox(width: 10.r),
            Expanded(
              child: Text(
                selName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
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
}

// ---- Card image with lazy loading ----
class _GameCardImage extends StatefulWidget {
  final String box2dPath;
  final GameModel game;
  final int targetWidth;
  const _GameCardImage({
    super.key,
    required this.box2dPath,
    required this.game,
    required this.targetWidth,
  });
  @override
  State<_GameCardImage> createState() => _GameCardImageState();
}

class _GameCardImageState extends State<_GameCardImage> {
  ImageProvider? _imageProvider;
  bool _exists = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _GameCardImage old) {
    super.didUpdateWidget(old);
    if (old.box2dPath != widget.box2dPath ||
        old.targetWidth != widget.targetWidth) {
      _checked = false;
      _exists = false;
      _imageProvider = null;
      _resolve();
    }
  }

  void _resolve() {
    if (_checked) return;
    final exists = File(widget.box2dPath).existsSync();
    if (!mounted) return;
    setState(() {
      _checked = true;
      _exists = exists;
      if (exists)
        _imageProvider = ResizeImage(
          FileImage(File(widget.box2dPath)),
          width: widget.targetWidth,
          allowUpscaling: false,
        );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const SizedBox.shrink();
    if (_exists && _imageProvider != null) {
      return Image(
        image: _imageProvider!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        isAntiAlias: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeIn,
            child: child,
          );
        },
        errorBuilder: (c, e, s) => _Placeholder(game: widget.game),
      );
    }
    return _Placeholder(game: widget.game);
  }
}

class _Placeholder extends StatelessWidget {
  final GameModel game;
  const _Placeholder({required this.game});
  @override
  Widget build(BuildContext context) {
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

class _CardRect {
  final double left, top, width, height;
  const _CardRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}
