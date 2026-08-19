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
    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      height: 84.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Identity Section: the ROM filename, and only the ROM
                // filename.
                //
                // There used to be a game title above this line. It was a
                // strict duplicate: the list sidebar sits beside this card and
                // its selected row renders the same resolved display name, so
                // the name was on screen twice, one of them painted straight
                // onto the game's fanart where pale artwork made it hard to
                // read. The filename is the one identity fact the sidebar does
                // not carry (it is what the scraped name was matched *from*),
                // so it is what stays, promoted into the space the title had.
                //
                // Consequence worth knowing: this line is only populated for
                // scraped games — `GameListService` sets the flag exclusively
                // on the scraped branch, because a filename under a name
                // derived from that same filename says nothing. For an
                // unscraped game, or a user running `preferFileName`, the
                // footer now carries no identity text at all and the sidebar
                // row is the only place the name appears. That is deliberate;
                // the blank line is still laid out so the action row below
                // keeps a constant baseline either way.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: RepaintBoundary(
                        child: Text(
                          game.showRomFileNameSubtitle ? game.romname : '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          strutStyle: StrutStyle(
                            fontSize: 16.r,
                            height: 1.15,
                            forceStrutHeight: true,
                          ),
                          style: TextStyle(
                            // Full white at w600: as the only line left it is
                            // the primary text here, not a subtitle under a
                            // heading, and the old 12.r/0.72 treatment let
                            // pale fanart through the letterforms.
                            color: Colors.white,
                            fontSize: 16.r,
                            fontWeight: FontWeight.w600,
                            height: 1.15,
                            shadows: [
                              Shadow(
                                blurRadius: 1.r,
                                color: Colors.black,
                                offset: const Offset(2, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8.r),

                // Actionable Section: Compact status indicators and primary Play button.
                ExcludeFocus(
                  child: Row(
                    children: [
                      // Game rating.
                      if (game.rating > 0) ...[
                        _SteamStyleRating(game: game),
                        SizedBox(width: 8.r),
                      ],

                      // RetroAchievements Progress. The indicator eases out to
                      // fill the gap to PLAY (LayoutBuilder gives it a concrete
                      // target width so the change animates instead of
                      // snapping) unless the play-time pill is there, in which
                      // case it rests at its natural width, left-aligned.
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Align(
                            alignment: Alignment.centerLeft,
                            child: _buildCompactAchievementsIndicator(
                              context,
                              availableWidth: constraints.maxWidth,
                              hasPlayTime:
                                  GameUtils.formatPlayTime(
                                    game.playTime ?? 0,
                                  ) !=
                                  '0s',
                            ),
                          ),
                        ),
                      ),
                      // Accumulated play time, shown as its own pill to the
                      // left of PLAY (only once the game has been played).
                      if (GameUtils.formatPlayTime(game.playTime ?? 0) !=
                          '0s') ...[
                        SizedBox(width: 8.r),
                        _PlayTimePill(game: game),
                      ],

                      // Cloud-sync state for this game. It used to sit at the
                      // foot of the vertical action rail; with the rail gone
                      // this row is where it lives. Every "nothing to say"
                      // state collapses to zero size, so the gap before PLAY
                      // travels with the widget rather than sitting beside it.
                      NeoSyncStatusIcon(
                        system: system,
                        game: game,
                        syncProvider: syncProvider,
                        size: 22.0,
                        margin: EdgeInsets.only(left: 8.r),
                      ),

                      // Consistent 8.r gap before PLAY, matching the spacing
                      // between the rating, RA and play-time pills.
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
    required bool hasPlayTime,
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

    // The badge fills its (Expanded) slot unless a play-time pill is claiming
    // the space to its right; otherwise it would leave dead space between
    // itself and PLAY. When one is there it rests at 120.r. The width is
    // animated so the change eases in/out.
    final bool expand = !hasPlayTime;
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
        // Drive the width from a single 0..1 factor on the same 250ms /
        // easeOutCubic timing as the sidebar margin, so the pill expands in
        // lockstep with the legend slide (one motion) rather than shifting
        // into place first and then easing its width (two steps).
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: expand ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Container(
            width: 120.r + (availableWidth - 120.r) * t,
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
            child: child,
          ),
          child: Padding(
            // Symmetric 8.r horizontal inset so neither the trophy icon nor the
            // progress bar hugs the pill border. The progress column is always
            // Expanded, so it simply absorbs the padding at any pill width (the
            // shown/hidden width animation never overflows).
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

/// A Steam-inspired rating badge that interpolates color based on the score intensity.
class _SteamStyleRating extends StatelessWidget {
  final GameModel game;

  const _SteamStyleRating({required this.game});

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

    return Container(
      height: 45.r,
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
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
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.5),
            blurRadius: 3.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Symbols.star_rounded, color: ratingColor, size: 24.r),
          SizedBox(width: 4.r),
          // Reserve width for the widest possible value ("10") so the pill
          // stays a static size regardless of the current score (e.g. "1"
          // no longer renders narrower than "10"). Scale/font-independent.
          Stack(
            alignment: Alignment.centerLeft,
            children: [
              Opacity(
                opacity: 0,
                child: Text(
                  '10',
                  style: TextStyle(fontSize: 22.r, fontWeight: FontWeight.w900),
                ),
              ),
              Text(
                ratingValue.toStringAsFixed(0),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 22.r,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact pill showing the accumulated play time for a game, styled to match
/// the rating pill. Sits to the left of the PLAY button.
class _PlayTimePill extends StatelessWidget {
  final GameModel game;

  const _PlayTimePill({required this.game});

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
    return Container(
      height: 45.r,
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
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
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.5),
            blurRadius: 3.r,
            offset: Offset(2.0.r, 2.0.r),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Symbols.schedule_rounded,
            color: Theme.of(context).colorScheme.onSurface,
            size: 14.r,
          ),
          SizedBox(height: 1.r),
          Text(
            _formatClock(game.playTime ?? 0),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 10.r,
              fontWeight: FontWeight.w800,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
