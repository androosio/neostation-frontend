import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:flutter_localization/flutter_localization.dart';

class GameViewModeDropdown extends StatefulWidget {
  static final GlobalKey<GameViewModeDropdownState> globalKey =
      GlobalKey<GameViewModeDropdownState>();

  GameViewModeDropdown() : super(key: globalKey);

  @override
  State<GameViewModeDropdown> createState() => GameViewModeDropdownState();
}

class GameViewModeDropdownState extends State<GameViewModeDropdown> {
  final GlobalKey _buttonKey = GlobalKey();
  GlobalKey get buttonKey => _buttonKey;

  void showDropdown() {
    _showDropdown(context, _buttonKey);
  }

  void showDropdownFrom(GlobalKey anchorKey) {
    _showDropdown(context, anchorKey);
  }

  void _showDropdown(BuildContext context, GlobalKey anchorKey) async {
    final RenderBox? renderBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset offset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final Size size = renderBox?.size ?? Size.zero;
    final configProvider = context.read<SqliteConfigProvider>();

    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Game View Mode Dropdown",
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: GameViewModeOverlay(
            offset: offset + Offset(0, size.height + 6.r),
            width: 170.r,
          ),
        );
      },
    );

    if (result != null) {
      SfxService().playNavSound();
      if (result == 'view_list') {
        await configProvider.updateGameViewMode('list');
      } else if (result == 'view_grid') {
        await configProvider.updateGameViewMode('grid');
      } else if (result.startsWith('card_size_')) {
        final newSize = result.substring('card_size_'.length);
        await configProvider.updateGameGridColumns(newSize);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class _DropdownOption {
  final String value;
  final String label;
  final IconData icon;
  final String group;
  final bool isCardSize;

  _DropdownOption(
    this.value,
    this.label,
    this.icon, {
    required this.group,
    this.isCardSize = false,
  });
}

class GameViewModeOverlay extends StatefulWidget {
  final Offset offset;
  final double width;

  const GameViewModeOverlay({
    super.key,
    required this.offset,
    required this.width,
  });

  @override
  State<GameViewModeOverlay> createState() => _GameViewModeOverlayState();
}

class _GameViewModeOverlayState extends State<GameViewModeOverlay> {
  late GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;
  final ScrollController _scrollController = ScrollController();

  int _cardSizeIndex = 1;

  @override
  void initState() {
    super.initState();
    final config = context.read<SqliteConfigProvider>().config;
    final sizes = ['S', 'M', 'L', 'XL'];
    final idx = sizes.indexOf(config.gameGridColumns);
    _cardSizeIndex = idx >= 0 ? idx : 1;

    _selectedIndex = config.gameViewMode == 'grid' ? 1 : 0;

    _gamepadNav = GamepadNavigation(
      onNavigateUp: () {
        final count = _getOptions(context).length;
        setState(() {
          _selectedIndex = (_selectedIndex - 1 + count) % count;
        });
        _scrollToSelected();
        SfxService().playNavSound();
      },
      onNavigateDown: () {
        final count = _getOptions(context).length;
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % count;
        });
        _scrollToSelected();
        SfxService().playNavSound();
      },
      onNavigateLeft: _handleNavigateLeft,
      onNavigateRight: _handleNavigateRight,
      onSelectItem: _handleSelection,
      onBack: () => Navigator.pop(context),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'game_view_mode_overlay',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _scrollToSelected() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final options = _getOptions(context);
      if (_selectedIndex < 0 || _selectedIndex >= options.length) return;

      double position = 8.r;
      for (int i = 0; i < _selectedIndex; i++) {
        if (options[i].group != (i > 0 ? options[i - 1].group : null)) {
          position += 16.r;
          if (i > 0) position += 4.r;
        }
        position += options[i].isCardSize ? 32.r : 28.r;
      }
      if (_selectedIndex == 0 ||
          options[_selectedIndex].group != options[_selectedIndex - 1].group) {
        position += 16.r;
      }

      _scrollController.animateTo(
        position.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
      );
    });
  }

  void _handleNavigateLeft() {
    final options = _getOptions(context);
    if (_selectedIndex < 0 || _selectedIndex >= options.length) return;
    final opt = options[_selectedIndex];
    if (opt.isCardSize) {
      setState(() {
        _cardSizeIndex = (_cardSizeIndex - 1 + 4) % 4;
      });
      SfxService().playNavSound();
      _applyCardSize();
    }
  }

  void _handleNavigateRight() {
    final options = _getOptions(context);
    if (_selectedIndex < 0 || _selectedIndex >= options.length) return;
    final opt = options[_selectedIndex];
    if (opt.isCardSize) {
      setState(() {
        _cardSizeIndex = (_cardSizeIndex + 1) % 4;
      });
      SfxService().playNavSound();
      _applyCardSize();
    }
  }

  void _applyCardSize() {
    final sizes = ['S', 'M', 'L', 'XL'];
    final size = sizes[_cardSizeIndex];
    final configProvider = context.read<SqliteConfigProvider>();
    configProvider.updateGameGridColumns(size);
  }

  void _handleSelection() {
    final List<_DropdownOption> options = _getOptions(context);
    final opt = options[_selectedIndex];
    if (opt.isCardSize) {
      _applyCardSize();
      Navigator.pop(
        context,
        'card_size_${['S', 'M', 'L', 'XL'][_cardSizeIndex]}',
      );
      return;
    }
    Navigator.pop(context, opt.value);
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('game_view_mode_overlay');
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<_DropdownOption> _getOptions(BuildContext context) {
    final config = context.read<SqliteConfigProvider>().config;
    final List<_DropdownOption> options = [
      _DropdownOption(
        'view_list',
        AppLocale.listView.getString(context),
        Symbols.list_rounded,
        group: AppLocale.viewModeGroup.getString(context),
      ),
      _DropdownOption(
        'view_grid',
        AppLocale.gridView.getString(context),
        Symbols.grid_view_rounded,
        group: AppLocale.viewModeGroup.getString(context),
      ),
    ];

    if (config.gameViewMode == 'grid') {
      options.add(
        _DropdownOption(
          'card_size',
          '',
          Symbols.crop_free_rounded,
          group: AppLocale.cardSizeGroup.getString(context),
          isCardSize: true,
        ),
      );
    }

    return options;
  }

  @override
  Widget build(BuildContext context) {
    final configProvider = context.watch<SqliteConfigProvider>();
    final config = configProvider.config;

    return Stack(
      children: [
        Positioned(
          top: 42.r,
          left: 6.r,
          width: widget.width,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 8.r),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.2),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.r),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _buildItems(config),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildItems(dynamic config) {
    final options = _getOptions(context);
    List<Widget> children = [];
    String? currentGroup;

    for (int i = 0; i < options.length; i++) {
      final opt = options[i];
      if (opt.group != currentGroup) {
        if (currentGroup != null) {
          children.add(
            Divider(
              height: 4.r,
              thickness: 1,
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: 0.1),
            ),
          );
        }
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 6.r),
            child: Text(
              opt.group,
              style: TextStyle(
                fontSize: 10.r,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        );
        currentGroup = opt.group;
      }

      if (opt.isCardSize) {
        final sizes = ['S', 'M', 'L', 'XL'];
        final configInfo = context.read<SqliteConfigProvider>().config;
        final currentSizeIndex = sizes.indexOf(configInfo.gameGridColumns);
        final isFocused = i == _selectedIndex;

        children.add(
          InkWell(
            onTap: () {
              setState(() => _selectedIndex = i);
            },
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
            child: Container(
              height: 28.r,
              margin: EdgeInsets.symmetric(horizontal: 4.r, vertical: 2.r),
              padding: EdgeInsets.symmetric(horizontal: 12.r),
              decoration: BoxDecoration(
                color: isFocused
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8.r),
                border: isFocused
                    ? Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.3),
                        width: 1,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.crop_free_rounded,
                    size: 14.r,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: sizes.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final label = entry.value;
                        final isSelected =
                            (isFocused && idx == _cardSizeIndex) ||
                            (!isFocused && idx == currentSizeIndex);
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedIndex = i;
                              _cardSizeIndex = idx;
                            });
                            SfxService().playNavSound();
                            _applyCardSize();
                          },
                          focusColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(4.r),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6.r,
                              vertical: 2.r,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.secondary
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 11.r,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.onSecondary
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }

      bool isSelected = false;
      if (opt.value == 'view_list') {
        isSelected = config.gameViewMode == 'list';
      } else if (opt.value == 'view_grid') {
        isSelected = config.gameViewMode == 'grid';
      }

      final bool itemIsFocused = i == _selectedIndex;

      children.add(
        Container(
          height: 24.r,
          margin: EdgeInsets.symmetric(horizontal: 4.r, vertical: 2.r),
          decoration: BoxDecoration(
            color: itemIsFocused
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
            border: itemIsFocused
                ? Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.3),
                    width: 1,
                  )
                : null,
          ),
          child: InkWell(
            onTap: () {
              setState(() => _selectedIndex = i);
              _handleSelection();
            },
            onHover: (v) {
              if (v) {
                setState(() => _selectedIndex = i);
              }
            },
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12.r),
              child: Row(
                children: [
                  Icon(
                    opt.icon,
                    size: 14.r,
                    color: isSelected
                        ? Theme.of(context).colorScheme.secondary
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                  SizedBox(width: 8.r),
                  Expanded(
                    child: Text(
                      opt.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.r,
                        color: isSelected
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context).colorScheme.onSurface,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Symbols.check_rounded,
                      size: 14.r,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return children;
  }
}
