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
import '../../../../widgets/monospaced_clock.dart';
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

    // The clock has one home: the far right of the footer's last row, at a
    // fixed distance from the card's edge. It used to fall back onto the
    // metadata line for games with no achievements pill, which meant it jumped
    // a line up and back down as the selection moved between a matched game
    // and an unmatched one — the two sit next to each other in every list, so
    // the jump was constant. Now the *text* moves to meet it instead.
    final List<Widget> metadata = _buildMetadata(hasRating: hasRating);

    // No fixed height: the footer is as tall as whichever arrangement below it
    // takes. A `Positioned` with left/right/bottom and no height takes its
    // child's, so the block hugs its content and stays pinned to the bottom.
    // Every line inside keeps its own fixed height (see `_statusLineHeight` /
    // `_identityLineHeight` / `_bottomRowHeight`) so nothing resizes with the
    // text it holds — only the arrangement changes.
    //
    // The bottom padding is the slack the old fixed-height box used to leave
    // under the last row; without it the content would drop to the card's
    // edge.
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
            child: showsAchievements
                // With a pill, the block stacks: text lines, then the pill row
                // with the clock at its end.
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTextLines(context, metadata: metadata),
                      SizedBox(height: _pillGap.r),
                      SizedBox(
                        height: _bottomRowHeight,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: ExcludeFocus(
                                child: LayoutBuilder(
                                  builder: (context, constraints) =>
                                      _buildCompactAchievementsIndicator(
                                        context,
                                        availableWidth: constraints.maxWidth,
                                      ),
                                ),
                              ),
                            ),
                            if (hasPlayTime) ...[
                              SizedBox(width: 12.r),
                              _InlinePlayTime(game: game),
                            ],
                          ],
                        ),
                      ),
                    ],
                  )
                // Without one, the text lines move *into* the pill's slot
                // rather than sitting above an empty one. The row keeps the
                // pill's height, so the clock is at exactly the distance from
                // the card's edge that it is on a matched game — it is the
                // text beside it that changes place, not the number.
                : hasPlayTime
                ? SizedBox(
                    height: _bottomRowHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: _buildTextLines(context, metadata: metadata),
                        ),
                        SizedBox(width: 12.r),
                        _InlinePlayTime(game: game),
                      ],
                    ),
                  )
                // Nothing to put on that row at all: no pill, no clock. The
                // text lines are the whole footer.
                : _buildTextLines(context, metadata: metadata),
          ),
        ),
      ),
    );
  }

  /// The two text lines of the footer: the metadata strip and the filename.
  ///
  /// They are a unit because they travel together. With an achievements pill
  /// they sit above it; without one they move down into the row the pill would
  /// have had, so the footer never shows a blank band where a widget is not
  /// coming and the clock beside them does not have to move to compensate.
  ///
  /// Both lines are fixed-height, and the block is `MainAxisSize.min`, so it
  /// takes 33.r either way — comfortably inside the 45.r row it drops into.
  Widget _buildTextLines(
    BuildContext context, {
    required List<Widget> metadata,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Status Section: the read-only facts about this game, on their own
        // line above the filename — rating, player count, publisher, year,
        // genre, in that order.
        //
        // They are here rather than in the action row at the bottom because
        // that row is for controls — every pill in it should do something when
        // pressed, and a score and a clock never did. As inline glyph+text they
        // cost the artwork a line rather than a pill each, which is what lets
        // the line carry five facts instead of the one it started with.
        //
        // The strip is a marquee (see [ScrollingStatusLine]): a long publisher
        // on a narrow card would otherwise ellipsize the year away, and this
        // line's whole point is that all of it is legible eventually. It only
        // moves when it overflows.
        //
        // The line used to be laid out even when empty so the footer's geometry
        // never moved. That reservation stopped being worth its height once the
        // clock and the sync icon left for the rows below: an unscraped game
        // has none of these facts, so the common case was a blank band of
        // artwork above the filename.
        if (metadata.isNotEmpty) ...[
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
        // There used to be a game title above this. It was a strict duplicate:
        // the list sidebar sits beside this card and its selected row renders
        // the same resolved display name, so the name was on screen twice, one
        // of them painted straight onto the game's fanart where pale artwork
        // made it hard to read. The filename is the one identity fact the
        // sidebar does not carry (it is what the scraped name was matched
        // *from*), so it is what stays.
        //
        // Consequence worth knowing: the filename is only populated for scraped
        // games — `GameListService` sets the flag exclusively on the scraped
        // branch, because a filename under a name derived from that same
        // filename says nothing. For an unscraped game, or a user running
        // `preferFileName`, this line carries no text at all and the sidebar
        // row is the only place the name appears. That is deliberate; the blank
        // line is still laid out so the row below keeps a constant baseline
        // either way.
        //
        // The cloud-sync icon rides at the end of this line: it is the one
        // status glyph that is about the *file*, so it reads as a marker on the
        // filename rather than as one more fact in the status cluster above. It
        // is never what gives way when the name is too long — see
        // [_buildIdentityLine].
        SizedBox(
          height: _identityLineHeight,
          child: _buildIdentityLine(context),
        ),
      ],
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
const double _statusLine = 15;

/// Height of the footer's last row, matching the achievements pill's own 45.r.
/// The same whether the pill is in it or the two text lines have moved into its
/// place, which is what keeps the play-time clock at one height.
const double _bottomRow = 45;

/// Height of the identity line, fixed for the same reason: the filename is
/// empty for an unscraped game. Driven by the 16.0 sync icon that sits at the
/// end of it, not by the 13.r filename's forced strut.
const double _identityLine = 16;

/// Gap between the text lines and the pill row below them.
const double _pillGap = 8;

/// Slack under the last row, so the content does not sit on the card's edge.
const double _bottomPadding = 11;

/// Gap the tab panels keep between themselves and the footer.
const double _panelGap = 13;

double get _statusLineHeight => _statusLine.r;
double get _bottomRowHeight => _bottomRow.r;
double get _identityLineHeight => _identityLine.r;

/// How far above the card's bottom edge a tab panel should stop, given what
/// the footer under it will draw.
///
/// The footer is the only thing between a panel and the card's edge, and its
/// height is decided by [GameDetailsFooter.showsAchievementsFor]: with no
/// pill the whole action row collapses and a panel that still reserved room
/// for one would end above a band of bare artwork.
///
/// Unscaled, like the panels' own offsets — the caller applies `.r`.
double gameDetailsPanelBottomOffset({
  required bool showsAchievements,
  required bool hasPlayTime,
  required bool hasMetadata,
}) {
  final double textLines = (hasMetadata ? _statusLine + 2 : 0) + _identityLine;
  final double content = showsAchievements
      ? textLines + _pillGap + _bottomRow
      // Without a pill the text lines move into its row, so the row's height
      // is the whole block — unless there is no clock either, and the lines
      // are all there is.
      : (hasPlayTime ? _bottomRow : textLines);
  return content + _bottomPadding + _panelGap;
}

/// Whether [game] carries any of the facts the footer's status line draws.
///
/// Mirrors the conditions in `_buildMetadata`; keep the two in step.
bool gameDetailsFooterHasMetadata(GameModel game) =>
    game.rating > 0 ||
    game.players.isNotEmpty ||
    game.publisher.isNotEmpty ||
    game.year.isNotEmpty ||
    game.genre.isNotEmpty;

/// Whether [game] has a play-time clock on the footer's last row.
bool gameDetailsFooterHasPlayTime(GameModel game) =>
    GameUtils.formatPlayTime(game.playTime ?? 0) != '0s';

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

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Sized well past the 11.r it used to be: beside a 45.r pill, and the
        // only thing on that side of the row, the small reading looked like a
        // caption that had drifted there. Still the largest text in the footer,
        // since reading it at a glance from arm's length is the point, but
        // pulled back from the 20.r it briefly ran at — at that size it started
        // competing with the game's artwork rather than sitting on it.
        // `fill: 0` against the app-wide `IconThemeData(fill: 1.0)` in
        // `main.dart`, for the same reason as the grid footer's clock: filled,
        // this glyph is a solid disc with the hands knocked out of it, and a
        // white disc on fanart reads as a badge rather than a clock.
        Icon(
          Symbols.schedule_rounded,
          color: Colors.white,
          size: 20.r,
          fill: 0,
          shadows: _onArtShadows,
        ),
        SizedBox(width: 6.r),
        MonospacedClock(
          text: MonospacedClock.format(game.playTime ?? 0),
          style: TextStyle(
            color: Colors.white,
            fontSize: 18.r,
            fontWeight: FontWeight.w700,
            height: 1.15,
            shadows: _onArtShadows,
          ),
        ),
      ],
    );
  }
}
