import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/header_action_button.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import '../../../../models/retro_achievements_game_info.dart';

/// An overlay component that renders RetroAchievements progress, stats, and a navigable grid.
///
/// Handles heuristic sorting (unlocked first), percentage calculation, and
/// bidirectional gamepad navigation for trophy exploration.
class GameDetailsAchievementsTab extends StatefulWidget {
  final GameInfoAndUserProgress? gameInfo;
  final bool isLoading;

  /// How many achievements the bundled snapshot lists for this game, or `null`
  /// when it is not matched. Known without any lookup, which is what lets the
  /// header be right while [gameInfo] is still outstanding.
  final int? snapshotAchievementTotal;
  final VoidCallback onRefresh;
  final double topOffset;
  final double bottomOffset;
  final double leftOffset;
  final double rightOffset;
  final Widget? headerAction;

  /// Opens the manual match picker. Shown both when a set was found (the match
  /// may still be the wrong one) and when none was, which is where a user is
  /// most likely to want it.
  final VoidCallback? onFixMatch;

  const GameDetailsAchievementsTab({
    super.key,
    this.gameInfo,
    required this.isLoading,
    this.snapshotAchievementTotal,
    required this.onRefresh,
    this.topOffset = 12.0,
    this.bottomOffset = 110.0,
    this.leftOffset = 12.0,
    this.rightOffset = 12.0,
    this.headerAction,
    this.onFixMatch,
  });

  @override
  State<GameDetailsAchievementsTab> createState() =>
      GameDetailsAchievementsTabState();
}

class GameDetailsAchievementsTabState
    extends State<GameDetailsAchievementsTab> {
  int _selectedAchievementIndex = 0;
  final Map<int, GlobalKey> _achievementKeys = {};
  final ScrollController _scrollController = ScrollController();

  /// Whether the panel owns the D-pad.
  ///
  /// Reaching this tab must not swallow the D-pad: while inactive, left/right
  /// keep walking the details tabs and up/down keep moving the game list, so
  /// there is always a way out. A activates the panel, B leaves it.
  bool _isPanelActive = false;

  /// Which header action holds focus, or -1 while the badge grid does.
  ///
  /// Up from the grid's top row lands here, down goes back to the badges, and
  /// left/right walk the actions — so REFRESH and FIX MATCH are reachable
  /// without a touchscreen.
  int _headerFocusIndex = -1;

  /// Whether the panel currently owns the D-pad.
  bool get isPanelActive => _isPanelActive;

  /// Hands the D-pad to the panel. Returns whether the input was consumed.
  ///
  /// Refuses only when there is nothing to reach at all — no badges *and* no
  /// header action — since activating an empty panel is the trap this gate
  /// exists to prevent. An unmatched game keeps its FIX MATCH reachable.
  bool enterPanel() {
    if (_isPanelActive) return true; // Already inside — A stays consumed.

    final hasBadges = _getSortedAchievements().isNotEmpty;
    if (!hasBadges && _headerActions().isEmpty) return false;

    setState(() {
      _isPanelActive = true;
      // With no badges to land on, the header is the only place to be.
      _headerFocusIndex = hasBadges ? -1 : 0;
    });
    if (hasBadges) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToSelectedAchievement(),
      );
    }
    return true;
  }

  /// Gives the D-pad back to the details card. Returns whether it was held.
  bool exitPanel() {
    if (!_isPanelActive) return false;

    setState(() {
      _isPanelActive = false;
      _headerFocusIndex = -1;
    });
    return true;
  }

  /// Runs the focused header action (gamepad A).
  ///
  /// Always reports the button as consumed while the panel is active: A must
  /// not fall through and launch the game from under a panel the user is
  /// still navigating.
  bool activateFocused() {
    if (!_isPanelActive) return false;

    final actions = _headerActions();
    if (_headerFocusIndex >= 0 && _headerFocusIndex < actions.length) {
      SfxService().playNavSound();
      actions[_headerFocusIndex].onTap();
    }
    return true;
  }

  @override
  void didUpdateWidget(GameDetailsAchievementsTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A different game means a different set: start at its first badge rather
    // than an index that pointed into the previous game's grid.
    final oldId = oldWidget.gameInfo?.id;
    final newId = widget.gameInfo?.id;
    if (oldId != newId) {
      _selectedAchievementIndex = 0;
      _isPanelActive = false;
      _headerFocusIndex = -1;
    }
  }

  /// The header actions the D-pad can reach, in the order they are drawn.
  ///
  /// The gate chip is deliberately absent: it is a legend for A/B, not a
  /// button to land on. An unmatched game has no set to refresh, so FIX MATCH
  /// is all it offers.
  List<_HeaderAction> _headerActions() {
    return [
      if (widget.gameInfo != null)
        _HeaderAction(label: AppLocale.refresh, onTap: widget.onRefresh),
      if (widget.onFixMatch != null)
        _HeaderAction(label: AppLocale.raFixMatch, onTap: widget.onFixMatch!),
    ];
  }

  /// Moves header focus by [delta], clamped to the ends so the run of actions
  /// has edges rather than wrapping under the user.
  void _moveHeaderFocus(int delta) {
    final actions = _headerActions();
    if (actions.isEmpty) return;
    final next = (_headerFocusIndex + delta).clamp(0, actions.length - 1);
    if (next == _headerFocusIndex) return;
    setState(() => _headerFocusIndex = next);
  }

  /// Lazily retrieves or creates a GlobalKey for an achievement item to enable 'ensureVisible' logic.
  GlobalKey _getAchievementKey(int index) {
    return _achievementKeys.putIfAbsent(index, () => GlobalKey());
  }

  /// Sorts achievements by unlock status (priority) and then by original display order.
  List<Achievement> _getSortedAchievements() {
    if (widget.gameInfo == null) return [];
    final achievements = widget.gameInfo!.achievements.values.toList();
    achievements.sort((Achievement a, Achievement b) {
      final aUnlocked = a.dateEarned != null && a.dateEarned!.isNotEmpty;
      final bUnlocked = b.dateEarned != null && b.dateEarned!.isNotEmpty;

      // Secondary-sort unlocked achievements to the top of the grid.
      if (aUnlocked != bUnlocked) {
        return aUnlocked ? -1 : 1;
      }
      return a.displayOrder.compareTo(b.displayOrder);
    });
    return achievements;
  }

  /// Ensures the currently focused achievement is scrolled into the viewport.
  void _scrollToSelectedAchievement() {
    final key = _achievementKeys[_selectedAchievementIndex];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    }
  }

  /// Gamepad navigation delegate: Move focus up by one grid row (6 items), or
  /// out of the grid's top row and into the header actions.
  void moveUp() {
    if (!_isPanelActive) return;
    if (_headerFocusIndex >= 0) return; // Already at the top of the panel.

    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;

    if (_selectedAchievementIndex < 6) {
      if (_headerActions().isEmpty) return;
      setState(() => _headerFocusIndex = 0);
      return;
    }

    setState(() => _selectedAchievementIndex -= 6);
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus down by one grid row (6 items),
  /// or back into the grid from the header actions.
  void moveDown() {
    if (!_isPanelActive) return;

    final achievements = _getSortedAchievements();
    final count = achievements.length;

    if (_headerFocusIndex >= 0) {
      if (count == 0) return; // Nothing below the header to drop into.
      setState(() => _headerFocusIndex = -1);
      _scrollToSelectedAchievement();
      return;
    }

    if (count == 0) return;
    setState(() {
      if (_selectedAchievementIndex + 6 < count) {
        _selectedAchievementIndex += 6;
      }
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus left by one badge, or one header
  /// action while the header holds focus.
  void moveLeft() {
    if (!_isPanelActive) return;
    if (_headerFocusIndex >= 0) {
      _moveHeaderFocus(-1);
      return;
    }

    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      _selectedAchievementIndex =
          (_selectedAchievementIndex - 1 + count) % count;
    });
    _scrollToSelectedAchievement();
  }

  /// Gamepad navigation delegate: Move focus right by one badge, or one header
  /// action while the header holds focus.
  void moveRight() {
    if (!_isPanelActive) return;
    if (_headerFocusIndex >= 0) {
      _moveHeaderFocus(1);
      return;
    }

    final achievements = _getSortedAchievements();
    final count = achievements.length;
    if (count == 0) return;
    setState(() {
      _selectedAchievementIndex = (_selectedAchievementIndex + 1) % count;
    });
    _scrollToSelectedAchievement();
  }

  /// Action trigger delegate: Currently unused for achievements (selection is purely visual).
  void trigger() {}

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    // Scenario 1: Metadata is being fetched.
    if (widget.gameInfo == null) {
      if (widget.isLoading) {
        // Same shell, same header, same grid geometry as a resolved set: only
        // the numbers and the badges are outstanding. Replacing the panel with
        // a centred spinner and a "loading" line meant its whole shape changed
        // and changed back around a fetch, which read as a flash rather than
        // as progress. The count comes from the bundled snapshot, so for a
        // matched game the header is right from the first frame and only the
        // earned figure is a dash.
        final int? snapshotTotal = widget.snapshotAchievementTotal;

        return Positioned(
          left: widget.leftOffset.r,
          right: widget.rightOffset.r,
          top: widget.topOffset.r,
          bottom: widget.bottomOffset.r,
          child: Container(
            decoration: BoxDecoration(
              color: ChromeSurface.fill(context),
              borderRadius: radii.radiusExternal,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 2.r,
                  offset: Offset(2.0.r, 2.0.r),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Symbols.emoji_events_rounded,
                            color: Colors.orange,
                            size: 13.r,
                          ),
                          SizedBox(width: 8.r),
                          // A dash rather than a zero for the figure nobody
                          // has answered yet — the same reading the footer
                          // pill gives the same gap.
                          if (snapshotTotal != null && snapshotTotal > 0)
                            Text(
                              '\u2013 / $snapshotTotal  \u00b7  \u2013%',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.75),
                                fontSize: 11.r,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const Spacer(),
                          // Holds open exactly the height the settled header's
                          // action chips will take. A chip is taller than the
                          // count text beside it, so a header built without one
                          // is shorter than the header that replaces it, and
                          // the divider and the whole badge grid stepped down
                          // at the moment the set landed. Reserving it with the
                          // real widget rather than a measured constant is what
                          // keeps the two headers the same height if the chip's
                          // padding ever changes.
                          Visibility(
                            visible: false,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: HeaderActionButton(
                              // The settled legend carries a button glyph, and
                              // the glyph is what sets the chip's height. Match
                              // its box rather than load the image: nothing
                              // here is ever painted.
                              icon: SizedBox(width: 12.r, height: 12.r),
                              label: AppLocale.navigate
                                  .getString(context)
                                  .toUpperCase(),
                              onTap: () {},
                              backgroundColor: Colors.transparent,
                              foregroundColor: Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                      // The one moving element, and it sits exactly where the
                      // divider does once the set lands, so nothing shifts
                      // when it goes.
                      SizedBox(
                        height: 10.r,
                        child: Center(
                          child: LinearProgressIndicator(
                            minHeight: 1.r,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.1),
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.r),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The left pane holds the focused badge's text, and
                        // there is no focused badge yet.
                        const Expanded(flex: 4, child: SizedBox.shrink()),
                        SizedBox(width: 12.r),
                        Expanded(
                          flex: 6,
                          child: _AchievementsSkeleton(count: snapshotTotal),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 8.r),
              ],
            ),
          ),
        );
      }

      // Scenario 2: Data is missing or system is unsupported.
      return Positioned(
        left: widget.leftOffset.r,
        right: widget.rightOffset.r,
        top: widget.topOffset.r,
        bottom: widget.bottomOffset.r,
        child: Container(
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius: radii.radiusExternal,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.videogame_asset_off_rounded,
                  size: 48.r,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                SizedBox(height: 16.r),
                Text(
                  AppLocale.noAchievementsFound.getString(context),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14.r,
                  ),
                ),
                if (widget.onFixMatch != null) ...[
                  SizedBox(height: 12.r),
                  HeaderActionButton(
                    isFocused: _isPanelActive && _headerFocusIndex == 0,
                    label: AppLocale.raFixMatch
                        .getString(context)
                        .toUpperCase(),
                    onTap: widget.onFixMatch!,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // Scenario 3: Achievements resolved successfully.
    final achievements = _getSortedAchievements();
    final headerActions = _headerActions();
    final total = achievements.length;
    final unlocked = achievements
        .where((a) => a.dateEarned != null && a.dateEarned!.isNotEmpty)
        .length;
    final percentage = total > 0
        ? (unlocked / total * 100).toStringAsFixed(0)
        : '0';

    return Positioned(
      left: widget.leftOffset.r,
      right: widget.rightOffset.r,
      top: widget.topOffset.r,
      bottom: widget.bottomOffset.r,
      child: Container(
        decoration: BoxDecoration(
          color: ChromeSurface.fill(context),
          borderRadius: radii.radiusExternal,
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: 0.25),
              blurRadius: 2.r,
              offset: Offset(2.0.r, 2.0.r),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Contains progress stats and the manual refresh action.
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // One line, three zones: identity, progress, actions. The
                  // count is flexible so a long title can never crash into it
                  // (the header used to be two fixed Rows in a spaceBetween,
                  // which is why the title butted up against the count chip),
                  // and it is plain muted text rather than a filled pill: the
                  // card's own footer already carries the progress bar, so a
                  // second high-contrast block of the same numbers was the
                  // loudest thing in the panel.
                  Row(
                    children: [
                      Icon(
                        Symbols.emoji_events_rounded,
                        color: Colors.orange,
                        size: 13.r,
                      ),
                      SizedBox(width: 8.r),
                      // No title: the selected tab in the card's header strip
                      // is already the trophy, so naming the panel again only
                      // costs the actions room they need.
                      Text(
                        '$unlocked / $total  ·  $percentage%',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.75),
                          fontSize: 11.r,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          // The gate's affordance: which button takes the
                          // D-pad into the panel, and which gives it back.
                          // A legend, not a target — the D-pad walks the
                          // actions to its right, never this.
                          if (achievements.isNotEmpty) ...[
                            HeaderActionButton(
                              icon: Image.asset(
                                _isPanelActive
                                    ? 'assets/images/gamepad/Xbox_B_button.png'
                                    : 'assets/images/gamepad/Xbox_A_button.png',
                                width: 12.r,
                                height: 12.r,
                              ),
                              label:
                                  (_isPanelActive
                                          ? AppLocale.back.getString(context)
                                          : AppLocale.navigate.getString(
                                              context,
                                            ))
                                      .toUpperCase(),
                              onTap: () {
                                SfxService().playNavSound();
                                if (_isPanelActive) {
                                  exitPanel();
                                } else {
                                  enterPanel();
                                }
                              },
                              backgroundColor: _isPanelActive
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              foregroundColor: _isPanelActive
                                  ? Theme.of(context).colorScheme.onSecondary
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                            SizedBox(width: 6.r),
                          ],
                          // Label-only chips: they are D-pad targets now, so a
                          // button glyph on them would advertise a shortcut
                          // that no longer exists.
                          for (final (index, action) in headerActions.indexed)
                            Padding(
                              padding: EdgeInsets.only(
                                left: index == 0 ? 0 : 6.r,
                              ),
                              child: HeaderActionButton(
                                label: action.label
                                    .getString(context)
                                    .toUpperCase(),
                                onTap: () {
                                  setState(() => _headerFocusIndex = index);
                                  action.onTap();
                                },
                                isFocused:
                                    _isPanelActive &&
                                    _headerFocusIndex == index,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onSurface,
                              ),
                            ),
                          if (widget.headerAction != null) ...[
                            SizedBox(width: 6.r),
                            widget.headerAction!,
                          ],
                        ],
                      ),
                    ],
                  ),
                  Divider(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                    height: 10.r,
                  ),
                ],
              ),
            ),

            // Content: Dual-pane layout (Metadata on left, Grid on right).
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.r),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 4,
                      child: _SelectedAchievementInfo(
                        achievements: achievements,
                        selectedIndex: _selectedAchievementIndex,
                      ),
                    ),
                    SizedBox(width: 12.r),
                    Expanded(
                      flex: 6,
                      child: _AchievementsGrid(
                        achievements: achievements,
                        selectedIndex: _selectedAchievementIndex,
                        // The badges are only live while the header cursor
                        // is parked.
                        isFocused: _isPanelActive && _headerFocusIndex < 0,
                        scrollController: _scrollController,
                        getKey: _getAchievementKey,
                        onSelect: (index) {
                          SfxService().playNavSound();
                          setState(() {
                            _selectedAchievementIndex = index;
                            // A tap is the touch equivalent of the A gate.
                            _isPanelActive = true;
                            _headerFocusIndex = -1;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 8.r),
          ],
        ),
      ),
    );
  }
}

/// A compact button styled for the achievement header.
/// A D-pad reachable action in the achievements header.
class _HeaderAction {
  /// Localization key for the chip's label.
  final String label;

  final VoidCallback onTap;

  const _HeaderAction({required this.label, required this.onTap});
}

/// Pane that displays the title, description, and point value of the focused achievement.
class _SelectedAchievementInfo extends StatelessWidget {
  final List<Achievement> achievements;
  final int selectedIndex;

  const _SelectedAchievementInfo({
    required this.achievements,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    if (achievements.isEmpty) return const SizedBox.shrink();
    final safeIndex = selectedIndex.clamp(0, achievements.length - 1);
    final achievement = achievements[safeIndex];
    final isUnlocked =
        achievement.dateEarned != null && achievement.dateEarned!.isNotEmpty;

    // Title, description and points read as one block. They used to be pinned
    // to opposite ends of the pane, which left a gap the size of the artwork
    // grid between a two-line description and its points chip.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              achievement.title,
              style: TextStyle(
                color: isUnlocked
                    ? Colors.orange
                    : Theme.of(context).colorScheme.onSurface,
                fontSize: 10.r,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 6.r),
            Text(
              achievement.description,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 9.r,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8.r),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondary,
                    borderRadius: radii.radiusInternal,
                  ),
                  child: Text(
                    '${achievement.points} ${AppLocale.points.getString(context)}',
                    style: TextStyle(color: Colors.white, fontSize: 9.r),
                  ),
                ),
                if (isUnlocked) ...[
                  SizedBox(width: 6.r),
                  Text(
                    AppLocale.unlocked.getString(context),
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 10.r,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Navigable grid of trophy badges loaded dynamically from RetroAchievements infrastructure.
/// Placeholder badges shown while a set is being fetched.
///
/// Mirrors [_AchievementsGrid]'s geometry exactly, so the real badges land in
/// the tiles the placeholders were already occupying instead of arriving into
/// an empty pane. Static rather than shimmering: the header's progress line is
/// already saying that something is happening, and a second animation for the
/// same fact is the noise this panel was rebuilt to lose.
class _AchievementsSkeleton extends StatelessWidget {
  /// How many tiles to draw. Falls back to a plausible grid when the snapshot
  /// has no count, and is capped because the pane scrolls anyway — the tiles
  /// past the fold would never be seen.
  final int? count;

  const _AchievementsSkeleton({required this.count});

  static const int _fallbackCount = 24;
  static const int _maxCount = 36;

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    final int tiles = (count ?? _fallbackCount).clamp(1, _maxCount);

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 4.r,
        mainAxisSpacing: 4.r,
        childAspectRatio: 1.0,
      ),
      itemCount: tiles,
      itemBuilder: (context, index) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.06),
          borderRadius: radii.radiusInternal,
        ),
      ),
    );
  }
}

class _AchievementsGrid extends StatelessWidget {
  final List<Achievement> achievements;
  final int selectedIndex;
  final ScrollController scrollController;
  final GlobalKey Function(int) getKey;
  final ValueChanged<int> onSelect;

  /// Whether the grid owns the D-pad. Drives how loud the cursor is drawn: a
  /// full cursor on a grid that ignores the D-pad is what made the tab look
  /// stuck.
  final bool isFocused;

  const _AchievementsGrid({
    required this.achievements,
    required this.selectedIndex,
    required this.isFocused,
    required this.scrollController,
    required this.getKey,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    return GridView.builder(
      controller: scrollController,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 4.r,
        mainAxisSpacing: 4.r,
        childAspectRatio: 1.0,
      ),
      itemCount: achievements.length,
      itemBuilder: (context, index) {
        final achievement = achievements[index];
        final isUnlocked =
            achievement.dateEarned != null &&
            achievement.dateEarned!.isNotEmpty;
        final isSelected = index == selectedIndex;

        return GestureDetector(
          key: getKey(index),
          onTap: () => onSelect(index),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).colorScheme.secondary.withValues(
                        alpha: isFocused ? 1.0 : 0.35,
                      )
                    : (isUnlocked
                          ? Colors.orange.withValues(alpha: 0.5)
                          : Colors.transparent),
                width: isSelected ? 2.r : 1.r,
              ),
              borderRadius: radii.radiusInternal,
            ),
            child: ClipRRect(
              borderRadius: radii.radiusInternal,
              child: Image.network(
                // Use the standard RA Badge CDN protocol for locked vs unlocked icons.
                isUnlocked
                    ? 'https://media.retroachievements.org/Badge/${achievement.badgeName}.png'
                    : 'https://media.retroachievements.org/Badge/${achievement.badgeName}_lock.png',
                cacheWidth: 64,
                fit: BoxFit.cover,
              ),
            ),
          ),
        );
      },
    );
  }
}
