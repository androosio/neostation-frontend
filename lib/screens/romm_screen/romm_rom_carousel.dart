import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../models/romm_rom.dart';
import '../../providers/romm_provider.dart';
import '../../services/game_legend_visibility.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../services/sfx_service.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/letter_jump.dart';
import '../../widgets/legend_edge_reshow_zone.dart';
import '../../widgets/native_carousel.dart';
import '../../widgets/romm_action_buttons.dart';
import '../app_screen.dart';
import 'romm_cover_aspect.dart';
import 'romm_rom_card.dart';

/// Cover-flow view for the RomM browser's ROM view.
///
/// The remote sibling of the local library's `GamesCarousel`: the same
/// [NativeCarousel] paging one artwork card at a time, the same alphabet bar
/// with held-direction letter jumping, and the same debounced settled-selection
/// chrome. Covers come off the network and the library is paged, so swiping
/// towards the end of the loaded set asks RomM for the next page.
class RommRomCarousel extends StatefulWidget {
  final RommProvider provider;
  final List<RommRom> roms;
  final List<String> romFolders;

  /// Index to open on, so the selection survives a view-mode switch.
  final int initialIndex;
  final ValueChanged<int> onIndexChanged;

  /// A / the on-card control — start (or cancel) the ROM's download.
  final ValueChanged<RommRom> onConfirm;
  final ValueChanged<RommRom> onCancel;
  final VoidCallback onBack;

  /// X — cycles grid → carousel → list.
  final VoidCallback onToggleView;

  /// Footer for the settled selection, built by the host so it keeps ownership
  /// of the open platform / collection context.
  final Widget Function(RommRom? focused) footerBuilder;

  const RommRomCarousel({
    super.key,
    required this.provider,
    required this.roms,
    required this.romFolders,
    required this.initialIndex,
    required this.onIndexChanged,
    required this.onConfirm,
    required this.onCancel,
    required this.onBack,
    required this.onToggleView,
    required this.footerBuilder,
  });

  @override
  State<RommRomCarousel> createState() => _RommRomCarouselState();
}

class _RommRomCarouselState extends State<RommRomCarousel> {
  final GlobalKey<NativeCarouselState> _carouselKey = GlobalKey();
  final ScrollController _letterBarController = ScrollController();

  late GamepadNavigation _gamepadNav;
  int _currentIndex = 0;

  // Debounced "settled" selection driving the footer + legend, so that chrome
  // isn't rebuilt on every frame of a fast-swipe burst.
  int _settledIndex = 0;
  Timer? _settleTimer;
  DateTime? _lastNavTime;
  bool _isNavigatingFast = false;
  static const Duration _fastNavThreshold = Duration(milliseconds: 150);
  static const Duration _chromeSettleDelay = Duration(milliseconds: 160);
  String? _chromeSig;
  Widget? _chromeFooter;
  Widget? _chromeLegend;

  final Map<String, double> _letterWidthCache = {};

  // True while a deferred page request is already queued for after this frame.
  bool _pageRequestScheduled = false;

  static const String _navLayerId = 'romm_rom_carousel';

  int get _romCount => widget.roms.isEmpty ? 1 : widget.roms.length;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, _romCount - 1);
    _settledIndex = _currentIndex;
    _initializeGamepad();
    GameLegendVisibility.hidden.addListener(_onLegendVisibilityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToCurrentLetter();
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    GameLegendVisibility.hidden.removeListener(_onLegendVisibilityChanged);
    GamepadNavigationManager.popLayer(_navLayerId);
    _gamepadNav.dispose();
    _letterBarController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme / MediaQuery / ScreenUtil may have changed; drop memoized chrome.
    _chromeSig = null;
  }

  @override
  void didUpdateWidget(RommRomCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Length, not identity: RommProvider.roms hands out a fresh unmodifiable
    // copy on every read, so an identity check reports "changed" on every
    // notification. Paging only appends, and a change of platform/collection
    // remounts this widget via its key.
    if (widget.roms.length != oldWidget.roms.length) {
      _letterWidthCache.clear();
      if (_currentIndex >= widget.roms.length) {
        _currentIndex = (widget.roms.length - 1).clamp(0, 999999);
        _settledIndex = _currentIndex;
      }
    }
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () {
        SfxService().playNavSound();
        _carouselKey.currentState?.previousPage();
      },
      onNavigateRight: () {
        SfxService().playNavSound();
        _carouselKey.currentState?.nextPage();
      },
      onSelectItem: _confirmSelected,
      onBack: widget.onBack,
      onXButton: widget.onToggleView,
      onLetterJump: _letterJump, // Held D-pad left/right → alphabet skipping.
      letterJumpAxis: LetterJumpAxis.horizontal,
      onSelectModifierB: _toggleLegend, // Select + B - Hide/show legend.
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _navLayerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _toggleLegend() {
    SfxService().playNavSound();
    GameLegendVisibility.toggle();
  }

  void _onLegendVisibilityChanged() {
    if (mounted) setState(() {});
  }

  RommRom? get _focusedRom => widget.roms.isEmpty
      ? null
      : widget.roms[_settledIndex.clamp(0, widget.roms.length - 1)];

  void _confirmSelected() {
    if (widget.roms.isEmpty) return;
    widget.onConfirm(
      widget.roms[_currentIndex.clamp(0, widget.roms.length - 1)],
    );
  }

  // ---- Alphabet bar ----

  String _letterFor(RommRom rom) => LetterJump.letterForName(rom.name);

  List<String> get _uniqueLetters {
    final letters = <String>[];
    for (final rom in widget.roms) {
      final letter = _letterFor(rom);
      if (letters.isEmpty || letters.last != letter) letters.add(letter);
    }
    return letters;
  }

  int _firstIndexForLetter(String letter) {
    for (int i = 0; i < widget.roms.length; i++) {
      if (_letterFor(widget.roms[i]) == letter) return i;
    }
    return 0;
  }

  /// Skips to the neighbouring alphabetical group once left/right has been held
  /// long enough. Returns false at the ends so the caller falls back to a
  /// normal page step.
  bool _letterJump(bool forward) {
    if (widget.roms.isEmpty) return false;
    final target = LetterJump.targetIndex(
      length: widget.roms.length,
      currentIndex: _currentIndex,
      forward: forward,
      letterAt: (index) => _letterFor(widget.roms[index]),
    );
    if (target == null) return false;
    // Jump rather than animate: at letter-jump cadence an animated slide across
    // dozens of entries would still be running when the next hop fires.
    _carouselKey.currentState?.jumpToPage(target);
    return true;
  }

  double _letterWidth(String letter, TextStyle style) {
    final cached = _letterWidthCache[letter];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(text: letter, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width + 16.r;
    _letterWidthCache[letter] = width;
    return width;
  }

  double _letterBarOffset(
    String current,
    List<String> letters,
    TextStyle style,
  ) {
    double offset = 4.r;
    for (final letter in letters) {
      if (letter == current) break;
      offset += _letterWidth(letter, style) + 6.r;
    }
    return offset;
  }

  void _scrollToCurrentLetter() {
    if (!_letterBarController.hasClients || widget.roms.isEmpty) return;
    final letters = _uniqueLetters;
    final current = _letterFor(
      widget.roms[_currentIndex.clamp(0, widget.roms.length - 1)],
    );
    final index = letters.indexOf(current);
    if (index == -1) return;
    final pos = _letterBarController.position;
    final style = TextStyle(fontSize: 11.r, fontWeight: FontWeight.w800);
    final target =
        _letterBarOffset(current, letters, style) -
        pos.viewportDimension / 2 +
        _letterWidth(current, style) / 2;
    pos.animateTo(
      target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  // ---- Paging ----

  void _onPageChanged(int index, CarouselPageChangeReason reason) {
    if (reason == CarouselPageChangeReason.manual) {
      SfxService().playNavSound();
    }
    final now = DateTime.now();
    _isNavigatingFast =
        _lastNavTime != null &&
        now.difference(_lastNavTime!) < _fastNavThreshold;
    _lastNavTime = now;

    setState(() => _currentIndex = index);
    widget.onIndexChanged(index);
    _scheduleChromeSettle();
    _scrollToCurrentLetter();
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    if (widget.provider.romsHasMore &&
        !widget.provider.loadingRoms &&
        _currentIndex >= widget.roms.length - 6) {
      _requestPage();
    }
  }

  /// Asks for the next page *after* the current frame. loadMoreRoms() notifies
  /// synchronously and the host screen watches this provider, so calling it
  /// straight from a page-change callback would dirty elements mid-layout.
  void _requestPage() {
    if (_pageRequestScheduled) return;
    _pageRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageRequestScheduled = false;
      if (!mounted) return;
      if (widget.provider.romsHasMore && !widget.provider.loadingRoms) {
        widget.provider.loadMoreRoms();
      }
    });
  }

  void _scheduleChromeSettle() {
    _settleTimer?.cancel();
    if (!_isNavigatingFast) {
      if (_settledIndex != _currentIndex) {
        setState(() => _settledIndex = _currentIndex);
      }
      return;
    }
    _settleTimer = Timer(_chromeSettleDelay, () {
      if (mounted && _settledIndex != _currentIndex) {
        setState(() => _settledIndex = _currentIndex);
      }
    });
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _buildSettledChrome();

    final letters = widget.roms.isEmpty ? const <String>[] : _uniqueLetters;
    final currentLetter = widget.roms.isEmpty
        ? ''
        : _letterFor(
            widget.roms[_currentIndex.clamp(0, widget.roms.length - 1)],
          );

    final textStyle = TextStyle(
      color: theme.colorScheme.onSurface,
      fontSize: 11.r,
      fontWeight: FontWeight.normal,
    );
    final selectedTextStyle = textStyle.copyWith(
      color: theme.colorScheme.onPrimary,
      fontWeight: FontWeight.w800,
    );

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              // Pad symmetrically so the centred card stays centred on-screen
              // while still clearing the vertical legend on the left.
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 60.r),
                child: widget.roms.isEmpty
                    ? const SizedBox.shrink()
                    : NativeCarousel(
                        key: _carouselKey,
                        itemCount: widget.roms.length,
                        initialIndex: _currentIndex.clamp(
                          0,
                          widget.roms.length - 1,
                        ),
                        itemBuilder: (context, index) {
                          final rom = widget.roms[index];
                          return KeyedSubtree(
                            key: ValueKey('romm_carousel_${rom.id}'),
                            child: _buildCard(
                              theme,
                              rom,
                              index,
                              index == _currentIndex,
                            ),
                          );
                        },
                        onPageChanged: _onPageChanged,
                      ),
              ),
            ),
            if (letters.isNotEmpty)
              _buildLetterBar(
                theme,
                letters,
                currentLetter,
                textStyle,
                selectedTextStyle,
              ),
            _chromeFooter!,
          ],
        ),
        // Vertical action-button legend, memoized on the settled selection.
        // Select + B slides it off the left edge. The centred carousel is left
        // in place — there is no left gutter for it to reflow into.
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          top: 12.r,
          left: GameLegendVisibility.hidden.value ? -60.r : 10.r,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: GameLegendVisibility.hidden.value ? 0.0 : 1.0,
            child: _chromeLegend!,
          ),
        ),
        // Touch: swipe-right from the left edge reveals a hidden legend.
        const LegendEdgeReshowZone(),
      ],
    );
  }

  /// A single carousel page: the cover sized to its own aspect within the page
  /// box, on the same shadowed, rounded plate the local carousel uses.
  Widget _buildCard(ThemeData theme, RommRom rom, int index, bool isSelected) {
    final url = widget.provider.service.coverUrl(rom);
    if (url != null && !RommCoverAspect.isMeasured(url)) {
      RommCoverAspect.measure(
        url,
        NetworkImage(
          url,
          headers: widget.provider.service.imageHeadersFor(url),
        ),
        () {
          if (mounted) setState(() {});
        },
      );
    }
    // Width/height, i.e. the inverse of the stored height/width ratio.
    final ratio =
        1 / (RommCoverAspect.ratioOf(url) ?? RommCoverAspect.fallback);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        double cardW, cardH;
        if (maxW / ratio <= maxH) {
          cardW = maxW;
          cardH = maxW / ratio;
        } else {
          cardH = maxH;
          cardW = maxH * ratio;
        }

        return Center(
          child: Container(
            width: cardW,
            height: cardH,
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.all(5.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isSelected ? 0.6 : 0.3),
                  blurRadius: isSelected ? 12.r : 6.r,
                  offset: Offset(2.r, 2.r),
                ),
              ],
            ),
            child: RommRomCard(
              rom: rom,
              provider: widget.provider,
              romFolders: widget.romFolders,
              isFocused: isSelected,
              layout: RommRomLayout.carousel,
              onDownload: () => widget.onConfirm(rom),
              onCancel: () => widget.onCancel(rom),
              onTap: () {
                if (index == _currentIndex) {
                  widget.onConfirm(rom);
                } else {
                  _carouselKey.currentState?.animateToPage(index);
                }
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildLetterBar(
    ThemeData theme,
    List<String> letters,
    String currentLetter,
    TextStyle textStyle,
    TextStyle selectedTextStyle,
  ) {
    return SizedBox(
      height: 30.r,
      child: SingleChildScrollView(
        controller: _letterBarController,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 4.r),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeInOut,
              left: _letterBarOffset(currentLetter, letters, selectedTextStyle),
              top: 0,
              bottom: 0,
              width: _letterWidth(currentLetter, selectedTextStyle),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary,
                  borderRadius: BorderRadius.circular(12.r),
                ),
              ),
            ),
            Row(
              children: letters.map((letter) {
                final isSelected = letter == currentLetter;
                return GestureDetector(
                  onTap: () {
                    SfxService().playNavSound();
                    _carouselKey.currentState?.animateToPage(
                      _firstIndexForLetter(letter),
                    );
                  },
                  child: Container(
                    width: _letterWidth(letter, selectedTextStyle),
                    height: 30.r,
                    margin: EdgeInsets.only(right: 6.r),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12.r),
                    ),
                    child: Text(
                      letter,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: isSelected ? selectedTextStyle : textStyle,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// (Re)builds the footer + legend only when the settled selection or its
  /// download state changes, so a fast-swipe burst reuses the same instances.
  void _buildSettledChrome() {
    final rom = _focusedRom;
    final download = rom == null ? null : widget.provider.downloadFor(rom.id);
    final sig =
        '$_settledIndex|${rom?.id}|${download?.status}|${download?.fraction}';
    if (sig == _chromeSig && _chromeFooter != null && _chromeLegend != null) {
      return;
    }
    _chromeSig = sig;
    _chromeFooter = widget.footerBuilder(rom);
    _chromeLegend = RommActionButtons(
      onBack: widget.onBack,
      onViewMode: widget.onToggleView,
      onDownload: rom == null
          ? null
          : () => download?.status == RommDownloadStatus.downloading
                ? widget.onCancel(rom)
                : widget.onConfirm(rom),
      isDownloading: download?.status == RommDownloadStatus.downloading,
      isDownloaded: download?.status == RommDownloadStatus.completed,
    );
  }
}
