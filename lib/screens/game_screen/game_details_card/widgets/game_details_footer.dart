import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/app_themes.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../models/retro_achievements_game_info.dart';
import '../../../../sync/i_sync_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import '../../../../themes/corner_radii.dart';
import '../../music/music_player.dart';
import 'package:neostation/utils/ra_coverage.dart';

/// A sticky footer component for the game details card that provides actionable controls and status summaries.
///
/// Manages high-level game interactions (Play), summarizes cloud synchronization
/// health, and provides quick access to trophy progress. Dynamically adjusts for specialized
/// systems like the Music Player.
class GameDetailsFooter extends StatelessWidget {
  final SystemModel system;
  final GameModel game;
  final bool isMusicSystem;
  final bool hasScreenScraper;
  final bool isSecondaryScreenActive;
  final bool cloudSyncEnabled;
  final ISyncProvider syncProvider;
  final AnimationController? syncIconController;
  final VoidCallback onShowAchievements;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;

  /// Launches the selected game. The same action A takes on the pad, and the
  /// same one a second tap on an already-selected sidebar row takes.
  final VoidCallback onPlayGame;

  /// Adds or removes this game from Favourites. The host owns the write and
  /// the follow-up (the Favourites system card appearing, the row leaving the
  /// Favourites view); the button only reports the current flag.
  final VoidCallback onToggleFavorite;

  /// Opens the per-game settings dialog — the same one Start opens.
  final VoidCallback onOpenGameSettings;

  const GameDetailsFooter({
    super.key,
    required this.system,
    required this.game,
    required this.isMusicSystem,
    required this.hasScreenScraper,
    required this.isSecondaryScreenActive,
    required this.cloudSyncEnabled,
    required this.syncProvider,
    this.syncIconController,
    required this.onShowAchievements,
    required this.hasRetroAchievements,
    required this.isLoadingAchievements,
    this.currentGameInfo,
    required this.onPlayGame,
    required this.onToggleFavorite,
    required this.onOpenGameSettings,
  });

  @override
  Widget build(BuildContext context) {
    // Scenario 1: Specialized Music Player UI.
    if (isMusicSystem) {
      return Positioned(
        bottom: -0.5.r,
        left: -0.5.r,
        right: -0.5.r,
        child: MusicPlayer(systemColor: system.colorAsColor),
      );
    }

    // Scenario 2: Standard Game Metadata UI.
    final bool hasRating = game.rating > 0;
    final bool showsAchievements = _showsAchievements(context);

    // One row, always the same height, in reading order: what the game *is*
    // on the left, what you can *do* with it on the right.
    //
    // The two text lines that used to sit above this row are gone. The
    // metadata strip (players, publisher, year, genre) reads better in the
    // game info tab, which already carried half of those facts, so the strip
    // is not repeated on the artwork, and the filename went with it. The
    // cloud-sync glyph that rode at the end of that line went too: the
    // grid/carousel footer is where it lives now.
    //
    // Fixed height, so the footer no longer resizes with what the selected
    // game happens to carry. The controls are always there, so the row is
    // always there — see [gameDetailsPanelBottomOffset], which is a constant
    // for the same reason.
    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Container(
            padding: EdgeInsets.only(
              left: 12.r,
              right: 12.r,
              bottom: _bottomPadding.r,
            ),
            child: SizedBox(
              height: _bottomRowHeight,
              // The whole row is touch-only. Every action on it has a hardware
              // binding already (A launches, Y opens the context menu, Start
              // opens settings), and a focusable widget inside the card would
              // put a second cursor in a view that owns its own selection.
              child: ExcludeFocus(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Readouts first: the score, then the achievements pill
                    // taking whatever the controls leave it.
                    if (hasRating) ...[
                      _InlineRating(game: game),
                      SizedBox(width: _rowGap),
                    ],
                    Expanded(
                      child: showsAchievements
                          ? LayoutBuilder(
                              builder: (context, constraints) =>
                                  _buildCompactAchievementsIndicator(
                                    context,
                                    availableWidth: constraints.maxWidth,
                                  ),
                            )
                          // Nothing to report, but the slot stays: it is what
                          // pushes the controls to the right margin.
                          : const SizedBox.shrink(),
                    ),
                    SizedBox(width: _rowGap),
                    // Controls. Two of the row's chips are gone: the cloud-sync
                    // state, which reported rather than acted and is on the
                    // grid/carousel footer anyway, and Random, which is a
                    // view-level action rather than one about the selected game
                    // and is still on the Y menu. They cost ~116.r between
                    // them, which is what the achievements pill needed to
                    // render at all -- see the class doc on [_bottomRow].
                    _FooterActionButton(
                      icon: Symbols.favorite_rounded,
                      // Filled and tinted when the game is already a
                      // favourite: the button is a toggle, so its state has to
                      // be readable without pressing it.
                      isOn: game.isFavorite == true,
                      onTap: onToggleFavorite,
                    ),
                    SizedBox(width: _rowGap),
                    _FooterActionButton(
                      icon: Symbols.settings_rounded,
                      onTap: onOpenGameSettings,
                    ),
                    SizedBox(width: _rowGap),
                    _buildPlayButton(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// High-contrast primary button for launching the emulator.
  ///
  /// It was dropped once as a third route to something A and a double tap on
  /// the sidebar row already did. It is back because those two are the only
  /// routes there are: the rail that carried every other touch affordance went
  /// with it, and a games view whose one visible control was an achievements
  /// pill gave touch nothing to press.
  Widget _buildPlayButton(BuildContext context) {
    // The one control on the row that keeps the theme's corner. Fully rounded
    // it read as one more chip in the set, and PLAY is not one of the set --
    // it is the row's primary action, and the squarer corner is part of what
    // separates it from the three icon buttons beside it.
    final BorderRadius radius =
        Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
        BorderRadius.circular(14.r);

    return Container(
      // Deliberately a fixed width. The achievements pill beside it is
      // Expanded, so anything this button takes comes straight out of that
      // pill; long labels are absorbed by scaling the text down rather than by
      // growing the button (see the FittedBox below).
      width: 104.r,
      height: _bottomRowHeight,
      decoration: BoxDecoration(
        color: const Color(0xFF2ECC71),
        borderRadius: radius,
        border: Border.all(color: const Color(0xFF36F184), width: 1.r),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 4.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashColor: Colors.white.withValues(alpha: 0.1),
          borderRadius: radius,
          onTap: () {
            SfxService().playEnterSound();
            onPlayGame();
          },
          child: Padding(
            padding: EdgeInsets.only(right: 10.r),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  width: 32.r,
                  height: 32.r,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
                SizedBox(width: 8.r),
                // The label is localized and the button is a fixed width, so
                // only the English "PLAY" fits at the full 14.r: the German,
                // Russian and CJK labels used to render past its right edge.
                // scaleDown shrinks just those to fit and never scales up, so
                // the button's footprint stays constant either way.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      AppLocale.playButton.getString(context),
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 14.r,
                        letterSpacing: 1.5,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// How many achievements this game has, if anything knows.
  ///
  /// The bundled snapshot already records the count for a matched game, so
  /// this costs no network call — only the user's *earned* count does. See
  /// _CompactAchievementsIndicator, which does the same.
  int get _achievementTotal {
    final int localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    return currentGameInfo?.numAchievements ?? localTotal;
  }

  /// Whether the achievements pill has anything to report.
  ///
  /// False collapses the whole action row, not just the pill, and the lines
  /// above drop into the space — so this is the one thing deciding how tall
  /// the footer is.
  ///
  /// Signed out, nothing ever loads achievement data, so the pill would settle
  /// on its "none" state for every game and claim the game has no achievements
  /// when the truth is that nobody asked. While a lookup is genuinely
  /// outstanding the pill stays (it says "Loading"); it is only a *settled*
  /// zero that hides it, which is the same condition the pill itself calls
  /// `noAchievements`.
  bool _showsAchievements(BuildContext context) => showsAchievementsFor(
    context,
    game: game,
    hasRetroAchievements: hasRetroAchievements,
    isLoadingAchievements: isLoadingAchievements,
    currentGameInfo: currentGameInfo,
  );

  /// [_showsAchievements] for callers that only hold the inputs — the tab
  /// panels above the footer, which need the same answer to know how much
  /// room the footer will take.
  static bool showsAchievementsFor(
    BuildContext context, {
    required GameModel game,
    required bool hasRetroAchievements,
    required bool isLoadingAchievements,
    GameInfoAndUserProgress? currentGameInfo,
  }) {
    if (!hasRetroAchievements) return false;
    if (!context.select<RetroAchievementsProvider, bool>(
      (ra) => ra.isConnected,
    )) {
      return false;
    }
    final int localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    final int total = currentGameInfo?.numAchievements ?? localTotal;
    return isLoadingAchievements || total > 0;
  }

  /// Resolves the current RetroAchievements progress into a compact visual badge.
  Widget _buildCompactAchievementsIndicator(
    BuildContext context, {
    required double availableWidth,
  }) {
    if (!_showsAchievements(context)) return const SizedBox.shrink();

    // Nothing rather than a splinter — see [_pillMinWidth].
    if (availableWidth < _pillMinWidth.r) return const SizedBox.shrink();

    // The badge fills its (Expanded) slot outright: whatever the row leaves
    // after the play-time clock beside it. It used to animate between 120.r and
    // full width, yielding the space to its right whenever a play-time pill was
    // there; the clock is inline text now and claims its width up front, so
    // there is no second width to ease to.
    final int total = _achievementTotal;
    final int? awarded = currentGameInfo?.numAwardedToUser;
    final bool knowsProgress = awarded != null && currentGameInfo != null;

    final bool noAchievements = !isLoadingAchievements && total == 0;

    // A dash rather than a zero while the earned count is outstanding, and
    // "Unknown" rather than "No Achievements" when the zero is a gap in what
    // the app could hash instead of an answer from RetroAchievements. See
    // _CompactAchievementsIndicator, which makes the same distinction.
    final String progressText = total > 0
        ? (knowsProgress ? '$awarded/$total' : '\u2013/$total')
        : (isLoadingAchievements
              ? AppLocale.loading.getString(context)
              : raCoverageAnswersZero(game.raCoverage)
              ? AppLocale.noAchievements.getString(context)
              : AppLocale.raCoverageUnknown.getString(context));

    // Whether the earned count is still outstanding for a game that has
    // achievements to earn. The bundled snapshot gives us the total instantly,
    // so this gap is every single selection change: the pill knows "49
    // achievements" before it knows "0 of them".
    final bool awaitingProgress = !knowsProgress && total > 0;

    // Always determinate. This used to run an indeterminate bar through the
    // gap above, which meant an orange sweep across the pill on *every* game
    // the user moved onto — a flash that said "working" about a lookup that
    // resolves in a moment and that the text ("-/49") already reports. A still
    // bar that fills in when the number lands is the same information without
    // the strobe.
    final double progress = knowsProgress && total > 0 ? awarded / total : 0.0;

    final theme = Theme.of(context);
    // Orange is for a real, known score. An empty bar that is empty only
    // because nobody has answered yet stays neutral, so the colour arriving is
    // itself the signal that the number is real.
    final Color statusColor = noAchievements || awaitingProgress
        ? theme.colorScheme.onSurface
        : Colors.orange;

    final String? gameIconUrl = currentGameInfo?.imageIcon.isNotEmpty == true
        ? 'https://media.retroachievements.org${currentGameInfo!.imageIcon}'
        : null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onShowAchievements();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: _controlRadius,
        child: Container(
          width: availableWidth,
          height: _bottomRowHeight,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius: _controlRadius,
            border: Border.all(
              color: Theme.of(context).colorScheme.outline,
              width: 1.r,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Padding(
            // Symmetric 8.r horizontal inset so neither the trophy icon nor the
            // progress bar hugs the pill border. The progress column is always
            // Expanded, so it simply absorbs the padding at any pill width.
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                // RetroAchievements game icon.
                ClipRRect(
                  borderRadius:
                      Theme.of(
                        context,
                      ).extension<CornerRadii>()?.radiusInternal ??
                      BorderRadius.circular(14.r),
                  child: Container(
                    width: _pillIconSize,
                    height: _pillIconSize,
                    color: theme.colorScheme.surface,
                    child: gameIconUrl != null
                        ? Image.network(
                            gameIconUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              Symbols.emoji_events_rounded,
                              color: statusColor,
                              size: 16.r,
                            ),
                          )
                        : Icon(
                            Symbols.emoji_events_rounded,
                            color: statusColor,
                            size: 16.r,
                          ),
                  ),
                ),
                SizedBox(width: 8.r),
                // Progress bar and achievement count. When the legend is hidden
                // the pill stretches, so let this column (and its bar) fill the
                // extra width via Expanded; otherwise keep the fixed 70.r width.
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: Text(
                          progressText.toUpperCase(),
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 10.r,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(height: 4.r),
                      // Hold the bar short of the pill's right edge so it
                      // doesn't run all the way across — mirrors the grid/
                      // carousel pill's right margin under the progress count.
                      Padding(
                        padding: EdgeInsets.only(right: 10.r),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4.r),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 5.r,
                            backgroundColor: theme.colorScheme.onSurface
                                .withValues(alpha: 0.1),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              statusColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The corner every chrome element on the row wears *except* PLAY: fully
/// rounded, so the square controls come out as circles and the achievements
/// pill as a stadium.
///
/// Deliberately not the theme's [CornerRadii]. That extension sets the corner
/// style for the app's panels and cards, and at its squarer settings this row
/// read as a strip of tiles; the controls are meant to read as a set of
/// buttons floating on the artwork, which is a shape, not a preference. PLAY
/// keeps the theme's corner precisely because it is *not* part of that set --
/// see [GameDetailsFooter._buildPlayButton].
BorderRadius get _controlRadius => BorderRadius.circular(_bottomRow.r);

/// Height of the footer's row, and the size of every square control on it.
///
/// One number, so the achievements pill, the sync chip, the three icon buttons
/// and PLAY all line up on both edges.
///
/// It is the achievements pill's own 45, which is what the row was built
/// around when the pill was the only thing on it.
///
/// Everything on the row is sized off this, so it is the dial for the row's
/// width budget -- and that budget is tight. The pill is the only Expanded
/// here, so it silently absorbs whatever the fixed items leave: at 45 with a
/// sync chip and a random button also on the row, what they left on a 1920
/// handheld was seven pixels, and the pill rendered full-height, right-shaped
/// and empty with no overflow to say so. Dropping those two is what pays for
/// 45; putting either back means bringing this number down with it. The
/// measurements and the sizing that does that are in
/// `docs/collections/08-list-footer-sizing.md`.
const double _bottomRow = 45;

/// The one gap between every pair of things on the row.
///
/// It was 8 either side of the achievements pill and 6 between the buttons,
/// which is close enough to look like a mistake rather than a rhythm -- the
/// controls read as unevenly spaced even though each pair was deliberate.
double get _rowGap => 6.r;

/// The score chip's width, fixed.
///
/// Two reasons it cannot size to its content. The number is one to four
/// characters ("8.5" against "10.0"), and since the achievements pill beside it
/// is the row's only Expanded, every character the score gains comes straight
/// out of the pill -- so the pill was a different width on every game, and on a
/// game scoring 10.0 it fell under [_pillMinWidth] and vanished outright. And a
/// readout that changes size as the cursor moves is exactly what the rest of
/// this footer was rebuilt to stop.
///
/// Sized for the common three-character case at full size; "10.0" is absorbed
/// by scaling the number down rather than by growing the chip, the same trade
/// PLAY's label makes.
const double _scoreWidth = 104;

/// The narrowest the achievements pill can be and still say anything: its
/// icon, the count and a bar with somewhere to fill.
///
/// Below this it is omitted outright rather than drawn as a sliver. The row's
/// budget is fixed items plus whatever is left, and "whatever is left" has no
/// floor of its own -- a card narrow enough leaves a few pixels, which is a
/// dark splinter between two chips rather than a control. Losing the pill on a
/// card that cannot hold one is the honest outcome; the D-pad still reaches
/// the achievements tab.
const double _pillMinWidth = 78;

/// Slack under the row, so the content does not sit on the card's edge.
const double _bottomPadding = 11;

/// Gap the tab panels keep between themselves and the footer.
const double _panelGap = 13;

double get _bottomRowHeight => _bottomRow.r;

/// The achievements pill's game icon: the row's height less its own vertical
/// padding, so the artwork fills the chip rather than floating in it.
double get _pillIconSize => (_bottomRow - 13).r;

/// How far above the card's bottom edge a tab panel should stop.
///
/// A constant now. The footer used to grow and shrink with the selected game —
/// a metadata strip that an unscraped game did not have, an achievements pill
/// that an unmatched one did not get — so a panel that reserved a fixed band
/// either ended above bare artwork or was overdrawn. The row holds the
/// controls, and those are there for every game, so there is nothing left to
/// vary.
///
/// Unscaled, like the panels' own offsets — the caller applies `.r`.
double gameDetailsPanelBottomOffset() =>
    _bottomRow + _bottomPadding + _panelGap;

/// One square control on the footer's row: a glyph on the same pill the
/// achievements indicator wears, so the row reads as a set.
///
/// [isOn] is for the favourite toggle, the one control here whose state is
/// worth reading at a glance: on, the glyph fills and takes the theme's
/// error colour, which is the same treatment the context menu gives a
/// membership that is already set.
class _FooterActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isOn;

  const _FooterActionButton({
    required this.icon,
    required this.onTap,
    this.isOn = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final BorderRadius radius = _controlRadius;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          onTap();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        borderRadius: radius,
        child: Container(
          width: _bottomRowHeight,
          height: _bottomRowHeight,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius: radius,
            border: Border.all(color: theme.colorScheme.outline, width: 1.r),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 22.r,
            fill: isOn ? 1 : 0,
            color: isOn
                ? AppThemes.getCustomColors(context).errorColor
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Score as a star and a number, at the head of the footer's row.
///
/// It has been in four places, and the middle two are the mistakes worth not
/// repeating. It started as a pill in this row, which was removed on the rule
/// that the row is for controls and a score answers to nothing. It then spent
/// a while as one more segment of the metadata marquee, at the strip's own
/// size — which cost it the emphasis along with the chrome, and let a long
/// publisher scroll it out of sight. It came back to the row as a bare glyph
/// and number on the artwork, which read as a caption that had drifted in.
///
/// It wears a chip again, and the rule it broke was the wrong rule: a row of
/// chips with one bare readout floating at its head does not read as "that one
/// is not pressable", it reads as unfinished. What separates the score from
/// the controls is that its chip has no ink and no tap target, not that it has
/// no chrome. The colour ramp — error at the bottom of the range, success at
/// the top — is what makes the number readable without reading it.
class _InlineRating extends StatelessWidget {
  final GameModel game;

  const _InlineRating({required this.game});

  @override
  Widget build(BuildContext context) {
    // Normalizes a 0-20 score to a 0.0-10.0 scale for color interpolation.
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    final colorRatio = (ratingValue - 1) / 9;
    final customColors = AppThemes.getCustomColors(context);
    final ratingColor = Color.lerp(
      customColors.errorColor,
      customColors.successColor,
      colorRatio,
    )!;

    final theme = Theme.of(context);

    return Container(
      width: _scoreWidth.r,
      height: _bottomRowHeight,
      // Tighter than the pill's own 8.r: at 45.r tall this chip is mostly air
      // already, and every unit of it is one the achievements pill beside it
      // does not get.
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      decoration: BoxDecoration(
        color: ChromeSurface.fill(context),
        borderRadius: _controlRadius,
        border: Border.all(color: theme.colorScheme.outline, width: 1.r),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 4.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Symbols.star_rounded, color: ratingColor, size: 22.r, fill: 1),
          SizedBox(width: 6.r),
          // scaleDown never scales up, so every score that already fits is
          // untouched and only "10.0" is pulled in.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                ratingValue.toStringAsFixed(1),
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 18.r,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
