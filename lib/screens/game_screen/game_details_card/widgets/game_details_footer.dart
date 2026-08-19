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
import '../../../../utils/game_utils.dart';
import '../../../../widgets/neo_sync_status_icon.dart';
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
  final VoidCallback onPlayGame;
  final VoidCallback onShowAchievements;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;

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
    required this.onPlayGame,
    required this.onShowAchievements,
    required this.hasRetroAchievements,
    required this.isLoadingAchievements,
    this.currentGameInfo,
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
    final bool hasPlayTime =
        GameUtils.formatPlayTime(game.playTime ?? 0) != '0s';

    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      height: 97.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status Section: the read-only facts about this game, on their
                // own line above the filename.
                //
                // They are here rather than in the action row at the bottom
                // because that row is for controls — every pill in it should do
                // something when pressed, and a score and a clock never did.
                // As inline glyph+text they cost the artwork a line rather than
                // three 45.r pills.
                //
                // Fixed height so the line is laid out whether or not there is
                // anything to put on it: an unrated, never-played game with
                // nothing to say about sync must not shorten the footer and
                // drag the action row up with it.
                SizedBox(
                  height: _statusLineHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Score, as a bare star and number rather than the pill it
                      // used to be. Colour still runs error -> success across
                      // the range, so a glance still reads good/bad.
                      if (hasRating) _InlineRating(game: game),

                      // Accumulated play time, once there is any.
                      if (hasPlayTime) ...[
                        if (hasRating) SizedBox(width: 12.r),
                        _InlinePlayTime(game: game),
                      ],

                      // Cloud-sync state for this game, third in the same
                      // cluster. Every "nothing to say" state of this widget
                      // collapses to zero size, so its leading gap has to
                      // travel with it rather than sit beside it — and it is
                      // only a gap at all when something precedes it, or a
                      // game with no rating and no play time would show the
                      // icon indented from the left edge on its own.
                      NeoSyncStatusIcon(
                        system: system,
                        game: game,
                        syncProvider: syncProvider,
                        size: 16.0,
                        margin: hasRating || hasPlayTime
                            ? EdgeInsets.only(left: 12.r)
                            : EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 2.r),

                // Identity Section: the ROM filename, alone on its line.
                //
                // There used to be a game title above this. It was a strict
                // duplicate: the list sidebar sits beside this card and its
                // selected row renders the same resolved display name, so the
                // name was on screen twice, one of them painted straight onto
                // the game's fanart where pale artwork made it hard to read.
                // The filename is the one identity fact the sidebar does not
                // carry (it is what the scraped name was matched *from*), so it
                // is what stays.
                //
                // Consequence worth knowing: the filename is only populated for
                // scraped games — `GameListService` sets the flag exclusively
                // on the scraped branch, because a filename under a name
                // derived from that same filename says nothing. For an
                // unscraped game, or a user running `preferFileName`, this line
                // carries no text at all and the sidebar row is the only place
                // the name appears. That is deliberate; the blank line is still
                // laid out so the action row below keeps a constant baseline
                // either way.
                SizedBox(
                  height: _identityLineHeight,
                  child: RepaintBoundary(
                    child: Text(
                      game.showRomFileNameSubtitle ? game.romname : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      strutStyle: StrutStyle(
                        fontSize: 13.r,
                        height: 1.15,
                        forceStrutHeight: true,
                      ),
                      style: TextStyle(
                        // Full white: the old 0.72 let pale fanart through the
                        // letterforms, which is where this line lost
                        // legibility first.
                        color: Colors.white,
                        fontSize: 13.r,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                        shadows: _onArtShadows,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 8.r),

                // Actionable Section. Everything left in this row responds to a
                // press: the achievements pill opens the achievements tab, PLAY
                // launches the game. The rating, play-time and sync widgets that
                // used to share it were inert — they looked like controls and
                // answered to nothing — so they moved up to the identity line
                // and this row is now controls only.
                ExcludeFocus(
                  child: Row(
                    children: [
                      // RetroAchievements progress, filling the gap to PLAY.
                      // Nothing competes for that space any more, so it simply
                      // takes what the Expanded gives it.
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) =>
                              _buildCompactAchievementsIndicator(
                                context,
                                availableWidth: constraints.maxWidth,
                              ),
                        ),
                      ),

                      // Consistent 8.r gap before PLAY.
                      SizedBox(width: 8.r),

                      // Primary Launch Control.
                      _buildPlayButtonCompact(context),
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

  /// High-contrast primary button for launching the emulator.
  ///
  /// Includes visual feedback for gamepad focus and displays accumulated play-time statistics.
  Widget _buildPlayButtonCompact(BuildContext context) {
    return Builder(
      builder: (context) {
        final isFocused = Focus.of(context).hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          // Deliberately a fixed width. The footer row has no slack — the
          // achievements pill beside it is Expanded, so anything this button
          // takes comes straight out of that pill (at 104.r it is already only
          // ~97.r wide on a 640x480-design handheld, just enough for "0/9").
          // Long labels are absorbed by scaling the text down, not by growing
          // the button; see the FittedBox below.
          width: 104.r,
          height: 45.r,
          decoration: BoxDecoration(
            color: isFocused
                ? const Color(0xFF36F184)
                : const Color(0xFF2ECC71),
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(14.r),
            border: Border.all(color: Color(0xFF36F184), width: 1.r),
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
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.white.withValues(alpha: 0.1),
              borderRadius:
                  Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                  BorderRadius.circular(14.r),
              onTap: () {
                SfxService().playEnterSound();
                onPlayGame();
              },
              child: Padding(
                padding: EdgeInsets.only(left: 0.r, right: 10.r),
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
                    // The label is localized and the button is a fixed width,
                    // so only "PLAY" fits at the full 14.r: "SPIELEN",
                    // "ИГРАТЬ" and "开始游戏" used to render past the pill's
                    // right edge and off the screen. scaleDown shrinks just
                    // those to fit — it never scales up, so every label that
                    // already fit is untouched — and keeps the button's
                    // footprint constant so the pills beside it don't move.
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
      },
    );
  }

  /// Resolves the current RetroAchievements progress into a compact visual badge.
  Widget _buildCompactAchievementsIndicator(
    BuildContext context, {
    required double availableWidth,
  }) {
    if (!hasRetroAchievements) return const SizedBox.shrink();

    // Signed out, nothing ever loads achievement data, so the badge below
    // would settle on its "none" state for every game and claim the game has
    // no achievements when the truth is that nobody asked.
    if (!context.select<RetroAchievementsProvider, bool>(
      (ra) => ra.isConnected,
    )) {
      return const SizedBox.shrink();
    }

    // The badge fills its (Expanded) slot outright. It used to animate between
    // 120.r and full width, yielding the space to its right whenever a
    // play-time pill was there; that pill now lives on the identity line, so
    // nothing can claim the gap between this badge and PLAY and there is no
    // second width to ease to.
    // The bundled snapshot already records how many achievements a matched
    // game has, so the total costs no network call — only the user's earned
    // count does. See _CompactAchievementsIndicator, which does the same.
    final int localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    final int total = currentGameInfo?.numAchievements ?? localTotal;
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

    // Indeterminate only while something is genuinely outstanding; a settled
    // "no achievements" gets an empty, still bar. See the compact pill.
    final double? progress = knowsProgress && total > 0
        ? awarded / total
        : (total > 0 || isLoadingAchievements ? null : 0.0);

    final theme = Theme.of(context);
    final Color statusColor = noAchievements
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
        borderRadius: BorderRadius.circular(8.r),
        child: Container(
          width: availableWidth,
          height: 45.r,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(14.r),
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
                    width: 32.r,
                    height: 32.r,
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

/// Drop shadow for text and glyphs painted straight onto the game's fanart.
///
/// Both text lines of this footer sit on artwork rather than on a chrome
/// surface, so everything on them carries the same shadow — filename, rating
/// and play-time clock read as one block, not as separately styled bits.
List<Shadow> get _onArtShadows => [
  Shadow(blurRadius: 1.r, color: Colors.black, offset: const Offset(2, 2)),
];

/// Height of the status line (rating + play time + sync), fixed so the line is
/// laid out even when the game has none of them and the footer's geometry never
/// moves. Driven by the tallest thing on it, the 16.0 sync icon.
double get _statusLineHeight => 16.r;

/// Height of the identity line, fixed for the same reason: the filename is
/// empty for an unscraped game. Just the 13.r filename's forced strut now that
/// the sync icon has joined the status line.
double get _identityLineHeight => 15.r;

/// Score as a bare star and number on the status line.
///
/// This was a 45.r pill on chrome in the action row below. It moved because
/// that row is for controls and a rating is not one: it showed a number and
/// answered to nothing. The colour ramp survives the move — error at the
/// bottom of the range, success at the top — since that is what makes the
/// number readable at a glance.
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Symbols.star_rounded,
          color: ratingColor,
          size: 15.r,
          fill: 1,
          shadows: _onArtShadows,
        ),
        SizedBox(width: 3.r),
        Text(
          ratingValue.toStringAsFixed(0),
          style: TextStyle(
            color: Colors.white,
            fontSize: 12.r,
            fontWeight: FontWeight.w800,
            height: 1.15,
            shadows: _onArtShadows,
          ),
        ),
      ],
    );
  }
}

/// Accumulated play time as a clock glyph and an HH:MM:SS reading on the
/// status line. Moved out of the action row for the same reason as
/// [_InlineRating]: it reported, it did not act.
class _InlinePlayTime extends StatelessWidget {
  final GameModel game;

  const _InlinePlayTime({required this.game});

  /// Formats accumulated seconds as a zero-padded HH:MM:SS clock.
  String _formatClock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${pad(h)}:${pad(m)}:${pad(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          Symbols.schedule_rounded,
          color: Colors.white,
          size: 13.r,
          shadows: _onArtShadows,
        ),
        SizedBox(width: 3.r),
        Text(
          _formatClock(game.playTime ?? 0),
          style: TextStyle(
            color: Colors.white,
            fontSize: 11.r,
            fontWeight: FontWeight.w700,
            height: 1.15,
            // Tabular figures so a ticking clock does not shuffle the line
            // width on every redraw.
            fontFeatures: const [FontFeature.tabularFigures()],
            shadows: _onArtShadows,
          ),
        ),
      ],
    );
  }
}
