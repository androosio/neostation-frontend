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
import 'scrolling_status_line.dart';
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
    final bool showsAchievements = _showsAchievements(context);

    // The clock has one home: the bottom row, right-aligned. It used to fall
    // back onto the status line for games with no achievements pill, which
    // meant it jumped a line up and back down as the user moved between a
    // matched game and an unmatched one — the two states are next to each
    // other in any list, so the jump was constant. The row now outlives the
    // pill: no pill just means the clock has the row to itself.
    final bool showsBottomRow = showsAchievements || hasPlayTime;
    final List<Widget> metadata = _buildMetadata(hasRating: hasRating);
    final bool showsStatusLine = metadata.isNotEmpty;

    // No fixed height any more: the achievements pill can be absent, and when
    // it is the footer has to give the artwork the 53.r back rather than hold
    // an empty reservation. A `Positioned` with left/right/bottom and no height
    // takes its child's, so the block hugs its content and stays pinned to the
    // bottom. The lines that are present keep their own fixed heights (see
    // `_statusLineHeight` / `_identityLineHeight`) so *they* never resize —
    // only which of them are there at all changes anything.
    //
    // The bottom padding is the slack the fixed-height box used to leave under
    // the action row; without it the content would drop to the card's edge.
    return Positioned(
      bottom: -0.5.r,
      left: -0.5.r,
      right: -0.5.r,
      child: ClipRRect(
        child: RepaintBoundary(
          child: Container(
            padding: EdgeInsets.only(left: 12.r, right: 12.r, bottom: 11.r),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status Section: the read-only facts about this game, on their
                // own line above the filename — rating, player count,
                // publisher, year, genre, in that order.
                //
                // They are here rather than in the action row at the bottom
                // because that row is for controls — every pill in it should do
                // something when pressed, and a score and a clock never did.
                // As inline glyph+text they cost the artwork a line rather than
                // a pill each, which is what lets the line carry five facts
                // instead of the one it started with.
                //
                // The strip is a marquee (see [ScrollingStatusLine]): a long
                // publisher on a narrow card would otherwise ellipsize the year
                // away, and this line's whole point is that all of it is
                // legible eventually. It only moves when it overflows.
                //
                // The line used to be laid out even when empty so the footer's
                // geometry never moved. That reservation stopped being worth
                // its height once the clock and the sync icon left for the rows
                // below: an unscraped game has none of these facts, so the
                // common case was a blank band of artwork above the filename.
                // It collapses outright now — the footer is sized by its
                // content, so the lines below simply move down.
                if (showsStatusLine) ...[
                  SizedBox(
                    height: _statusLineHeight,
                    child: ScrollingStatusLine(
                      resetKey: game.romname,
                      children: metadata,
                    ),
                  ),
                  SizedBox(height: 2.r),
                ],

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
                //
                // The cloud-sync icon rides at the end of this line: it is the
                // one status glyph that is about the *file*, so it reads as a
                // marker on the filename rather than as one more fact in the
                // status cluster above. It is never what gives way when the
                // name is too long — see `_buildIdentityLine`.
                SizedBox(
                  height: _identityLineHeight,
                  child: _buildIdentityLine(context),
                ),

                // Actionable Section: the achievements pill, with the play-time
                // clock to the right of it.
                //
                // The rating and sync widgets that used to share this row were
                // inert — they looked like controls and answered to nothing —
                // so they moved up to the lines above. PLAY went too: launching
                // is A on the pad, and a double tap on the already-selected
                // sidebar row for touch (`game_list_view.dart:348`), so the
                // button was a third route to something both of those already
                // do. The clock is inert as well, but it earns the space here:
                // the pill no longer needs the full width, and playtime next to
                // achievement progress reads as one "how far in am I" cluster.
                //
                // The row is kept at a fixed height and drawn for either
                // occupant, so a played game with no achievements shows the
                // clock in exactly the place a matched game does. Moving
                // between the two is otherwise a jump: unmatched games sit
                // right next to matched ones in every list.
                if (showsBottomRow) ...[
                  SizedBox(height: 8.r),
                  SizedBox(
                    height: _bottomRowHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Expanded either way: with a pill it is the pill's
                        // slot, without one it is the empty space that holds
                        // the clock out at the right edge.
                        Expanded(
                          child: showsAchievements
                              ? ExcludeFocus(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) =>
                                        _buildCompactAchievementsIndicator(
                                          context,
                                          availableWidth: constraints.maxWidth,
                                        ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (hasPlayTime) ...[
                          SizedBox(width: 12.r),
                          _InlinePlayTime(game: game),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The filename line: the ROM's name, and the cloud-sync glyph after it.
  ///
  /// Two layouts, chosen by measuring the name against the space it has:
  ///
  /// * It fits — the name is laid out at its own width and the glyph sits just
  ///   after it, reading as a marker on the name.
  /// * It does not — the name becomes a marquee filling the line and the glyph
  ///   is pushed hard against the right edge. The name is the only thing that
  ///   gives way here; the glyph stays whole and visible, because a truncated
  ///   filename still scrolls round to legible while a clipped status icon is
  ///   simply gone.
  ///
  /// The measurement has to know whether the glyph is there to reserve room
  /// for, and it collapses to nothing in most of its states — hence
  /// [NeoSyncStatusIcon.willRender] rather than a guess.
  Widget _buildIdentityLine(BuildContext context) {
    final String label = game.showRomFileNameSubtitle ? game.romname : '';
    final TextStyle style = TextStyle(
      // Full white: the old 0.72 let pale fanart through the letterforms,
      // which is where this line lost legibility first.
      color: Colors.white,
      fontSize: 13.r,
      fontWeight: FontWeight.w600,
      height: 1.15,
      shadows: _onArtShadows,
    );

    final bool hasSyncIcon = NeoSyncStatusIcon.willRender(
      system: system,
      game: game,
      syncProvider: syncProvider,
    );

    final Widget syncIcon = NeoSyncStatusIcon(
      system: system,
      game: game,
      syncProvider: syncProvider,
      size: 16.0,
      // Bare glyph, not the chip the grid/carousel footer uses: this line is
      // painted on artwork, and a filled surface behind the icon read as a
      // button sitting in the middle of a text line.
      showBackground: false,
      // Every "nothing to say" state of this widget collapses to zero size, so
      // its leading gap has to travel with it rather than sit beside it — and
      // it is only a gap at all when there is a name for it to follow, or an
      // unscraped game would show the icon indented from the left on its own.
      margin: label.isEmpty ? EdgeInsets.zero : EdgeInsets.only(left: 8.r),
    );

    final Widget text = RepaintBoundary(
      child: Text(
        label,
        maxLines: 1,
        // No wrapping and no ellipsis: whichever branch below is taken, this
        // text is laid out at its full width — either because it fits, or
        // because the marquee is going to scroll past its end.
        softWrap: false,
        strutStyle: StrutStyle(
          fontSize: 13.r,
          height: 1.15,
          forceStrutHeight: true,
        ),
        style: style,
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final double reserved = hasSyncIcon ? 16.r + 8.r : 0;
        final TextPainter painter = TextPainter(
          text: TextSpan(text: label, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final bool overflows =
            painter.width > (constraints.maxWidth - reserved);
        painter.dispose();

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (overflows)
              Expanded(
                child: ScrollingStatusLine(
                  resetKey: game.romname,
                  children: [text],
                ),
              )
            else
              text,
            syncIcon,
          ],
        );
      },
    );
  }

  /// The scraped facts for the status strip, separated and in reading order:
  /// rating, players, publisher, year, genre.
  ///
  /// Empty fields drop out entirely rather than rendering a placeholder, so an
  /// unscraped game returns an empty list and the whole line collapses. Nothing
  /// here is localized because nothing here is a label: every segment is either
  /// a glyph or the scraped value itself.
  List<Widget> _buildMetadata({required bool hasRating}) {
    final List<Widget> facts = [];

    // Score, as a bare star and number rather than the pill it used to be.
    // Colour still runs error -> success across the range, so a glance still
    // reads good/bad.
    if (hasRating) facts.add(_InlineRating(game: game));

    // A bare player count is ambiguous ("2" — of what?), so it keeps its glyph.
    // Publisher, year and genre are self-evident as plain words and would only
    // be made busier by one.
    if (game.players.isNotEmpty) {
      facts.add(_InlineFact(icon: Symbols.people_rounded, text: game.players));
    }
    if (game.publisher.isNotEmpty) {
      facts.add(_InlineFact(text: game.publisher));
    }
    if (game.year.isNotEmpty) {
      // Scraped years arrive as full timestamps as often as bare years; the
      // info tab pulls the four digits out the same way.
      facts.add(
        _InlineFact(text: RegExp(r'\d{4}').stringMatch(game.year) ?? game.year),
      );
    }
    if (game.genre.isNotEmpty) {
      facts.add(_InlineFact(text: game.genre));
    }

    // Interleave the separators rather than hanging one off each segment, so
    // the strip never ends on a dangling bar.
    final List<Widget> separated = [];
    for (int i = 0; i < facts.length; i++) {
      if (i > 0) separated.add(const _FactSeparator());
      separated.add(facts[i]);
    }
    return separated;
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
  bool _showsAchievements(BuildContext context) {
    if (!hasRetroAchievements) return false;
    if (!context.select<RetroAchievementsProvider, bool>(
      (ra) => ra.isConnected,
    )) {
      return false;
    }
    return isLoadingAchievements || _achievementTotal > 0;
  }

  /// Resolves the current RetroAchievements progress into a compact visual badge.
  Widget _buildCompactAchievementsIndicator(
    BuildContext context, {
    required double availableWidth,
  }) {
    if (!_showsAchievements(context)) return const SizedBox.shrink();

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

/// Height of the metadata strip, fixed because the marquee inside it needs a
/// bounded box to measure its overflow against. Driven by the tallest thing on
/// it, the 15.r rating star.
double get _statusLineHeight => 15.r;

/// Height of the bottom row, matching the achievements pill's own 45.r. Fixed
/// rather than taken from whatever is in it, so the play-time clock sits at the
/// same height whether or not the pill is beside it.
double get _bottomRowHeight => 45.r;

/// Height of the identity line, fixed for the same reason: the filename is
/// empty for an unscraped game. Driven by the 16.0 sync icon that sits at the
/// end of it, not by the 13.r filename's forced strut.
double get _identityLineHeight => 16.r;

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

/// One scraped fact on the status strip: an optional glyph and its value.
///
/// Deliberately plainer than [_InlineRating] — no colour ramp, no emphasis. The
/// strip is a credits line, and the eye should be able to skim past the parts
/// it does not want.
class _InlineFact extends StatelessWidget {
  final IconData? icon;
  final String text;

  const _InlineFact({this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, color: Colors.white, size: 13.r, shadows: _onArtShadows),
          SizedBox(width: 3.r),
        ],
        Text(
          text,
          maxLines: 1,
          // No ellipsis: the marquee is what handles a strip too wide for the
          // card, and a segment that truncated itself would never be readable
          // no matter how far the line scrolled.
          softWrap: false,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12.r,
            fontWeight: FontWeight.w600,
            height: 1.15,
            shadows: _onArtShadows,
          ),
        ),
      ],
    );
  }
}

/// The bar between two facts on the status strip.
class _FactSeparator extends StatelessWidget {
  const _FactSeparator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Text(
        '|',
        style: TextStyle(
          // Dimmer than the facts either side of it: it is punctuation, and at
          // full white it counted as a third thing to read between every pair.
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 12.r,
          fontWeight: FontWeight.w400,
          height: 1.15,
          shadows: _onArtShadows,
        ),
      ),
    );
  }
}

/// Accumulated play time as a clock glyph and an HH:MM:SS reading, at the right
/// end of the footer's bottom row. Moved out of the action row as a pill for
/// the same reason as [_InlineRating]: it reported, it did not act.
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
        // Sized well past the 11.r it used to be: beside a 45.r pill, and the
        // only thing on that side of the row, the small reading looked like a
        // caption that had drifted there. It is now the largest text in the
        // footer by some way, which is right — reading it at a glance from
        // arm's length is the point.
        Icon(
          Symbols.schedule_rounded,
          color: Colors.white,
          size: 22.r,
          shadows: _onArtShadows,
        ),
        SizedBox(width: 6.r),
        Text(
          _formatClock(game.playTime ?? 0),
          style: TextStyle(
            color: Colors.white,
            fontSize: 20.r,
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
