import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/models/retro_achievements_game_info.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/ra_coverage.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/utils/game_utils.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/widgets/marquee_text.dart';
import 'package:neostation/widgets/neo_sync_status_icon.dart';
import 'package:neostation/widgets/monospaced_clock.dart';
import 'package:neostation/themes/chrome_surface.dart';
import '../../themes/corner_radii.dart';

/// A reusable footer used by the game grid and carousel views.
///
/// Mirrors the layout of the details list footer: the game's name and the strip
/// of read-only facts under it are anchored to the left, while the score, the
/// mute hint, the RetroAchievements pill and the play-time clock are grouped on
/// the right.
///
/// **D15 — pills are for things that answer to a press.** That row used to hold
/// five things and exactly two of them did: the achievements pill and PLAY. The
/// rating, the play-time clock and the cloud-sync glyph were pure readouts
/// wearing the same pill chrome as the buttons beside them, which is what made
/// the footer read as cluttered — three controls that were not controls.
///
/// The first cut of that fix moved all three *out of the row*, onto the status
/// strip under the game's name. Two of them stayed out: the cloud-sync glyph
/// is a marker on the file and belongs beside the filename, and the clock came
/// back only because it inherited PLAY's slot. **The score's exile was the one
/// that cost more than it bought** — on the strip it was set at the strip's own
/// size, which made the number people scan a list for the smallest thing in the
/// footer.
///
/// So the rule is chrome, not position: the score and the clock sit in the row
/// again as bare glyph-plus-text at either end of it, with the pills between
/// them, and neither reads as pressable because neither has a surface. The
/// details card's bottom row is the same arrangement, and the two footers have
/// to agree — they disagreed about exactly this once already.
///
/// **PLAY is gone from this footer.** A card that is already selected launches
/// on a second tap, and A does it on a gamepad, so the button was an affordance
/// for something both input methods could already do. The play-time clock took
/// its place at the end of the row, with the achievements pill to its left —
/// the same arrangement, in the same order, as the details card's bottom row —
/// and it leaves the status strip so it is never read twice.
class GameViewFooter extends StatelessWidget {
  final GameModel game;
  final bool hasRetroAchievements;
  final bool isLoadingAchievements;
  final GameInfoAndUserProgress? currentGameInfo;
  final VoidCallback? onShowAchievements;

  /// Toggles global video sound. The grid and carousel have no video surface of
  /// their own — the preview plays on the secondary display — so this pill is
  /// their only mute affordance, mirroring the Select hint on the details card.
  /// Omit it to hide the pill.
  final VoidCallback? onToggleMute;

  /// Whether the selected game actually has a preview video. There is nothing
  /// to mute without one, so the pill stays hidden rather than offering a
  /// control that does nothing for this game.
  final bool hasVideo;

  /// Whether the selection is a subfolder rather than a game. A folder has no
  /// play time and no achievements, so the action row holds nothing for one.
  final bool isFolder;

  /// The game's *own* system and the active sync provider, for the cloud-sync
  /// status icon. This footer is where that indicator lives now that the
  /// vertical action rail is gone; both null hides it.
  final SystemModel? system;
  final ISyncProvider? syncProvider;

  const GameViewFooter({
    super.key,
    required this.game,
    this.hasRetroAchievements = false,
    this.isLoadingAchievements = false,
    this.currentGameInfo,
    this.onShowAchievements,
    this.onToggleMute,
    this.hasVideo = false,
    this.isFolder = false,
    this.system,
    this.syncProvider,
  });

  @override
  Widget build(BuildContext context) {
    // Plain scheme colours, no shadows: in both hosts the text already has a
    // background of its own to read against. The grid floats over its rows,
    // but the scrim under this footer finishes opaque in the band the text
    // sits in, so nothing scrolls through behind a glyph; the carousel's cards
    // stop where the footer starts, so nothing ever passed behind it there.
    // The halo that briefly covered the gap between those two facts was
    // painted in the background's own colour, which is what the scrim now
    // paints the band -- it could only ever converge on what is already there.
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Identity: the name, and the status strip under it.
          Expanded(child: _buildIdentityBlock(context, scheme)),

          SizedBox(width: 12.r),

          // Action section — see D15 on the class above. The play-time clock
          // is the one readout on it, and only because it inherited PLAY's
          // slot; any *new* fact about the game belongs on the status strip.
          ExcludeFocus(child: Row(children: _buildActions(context))),
        ],
      ),
    );
  }

  /// The right-hand end of the footer, spaced apart.
  ///
  /// Built as a list rather than inline so a hidden item leaves no spacer
  /// behind it: on a never-played game the achievements pill is the last thing
  /// on the row, and a trailing gap would push it off the right margin.
  ///
  /// The two readouts bracket the controls — score first, clock last, pills
  /// between — which is the same arrangement the details card's bottom row
  /// has. Neither wears a pill, so the row still reads as "the things that do
  /// something are the ones with chrome", which is what D15 was actually
  /// about; it is only the *row* the score was kept out of, and that turned
  /// out to cost more than it bought (see [_InlineRating]).
  List<Widget> _buildActions(BuildContext context) {
    final actions = <Widget>[
      if (game.rating > 0) _InlineRating(game: game),
      if (onToggleMute != null && hasVideo)
        _MuteHintPill(onToggleMute: onToggleMute!),
      // Signed out, no achievement data is ever loaded, so the pill would
      // render its "none" state for every game in the library and read as
      // "this game has no achievements" rather than "nobody asked
      // RetroAchievements". Say nothing instead.
      if (hasRetroAchievements &&
          context.select<RetroAchievementsProvider, bool>(
            (ra) => ra.isConnected,
          ))
        _CompactAchievementsIndicator(
          game: game,
          isLoading: isLoadingAchievements,
          gameInfo: currentGameInfo,
          onTap: onShowAchievements,
        ),
      if (_hasPlayTime) _InlinePlayTime(game: game),
    ];

    for (int i = actions.length - 1; i > 0; i--) {
      actions.insert(i, SizedBox(width: 6.r));
    }
    return actions;
  }

  /// Whether the game has been played for long enough to have a reading. The
  /// clock is hidden rather than showing `0s`.
  bool get _hasPlayTime =>
      !isFolder && GameUtils.formatPlayTime(game.playTime ?? 0) != '0s';

  /// The game's name, and under it the strip of things that only report.
  ///
  /// The strip carries the ROM filename and the cloud-sync glyph, separated by
  /// bars in the details footer's own punctuation. The rating used to lead it
  /// and no longer does: it is at the head of the action cluster now (see
  /// [_buildActions]), which is what took it out of competition with the
  /// filename for the same line.
  ///
  /// The strip is one fixed-height line whether or not anything is on it. This
  /// footer's height feeds back into the view above it — the grid and carousel
  /// take the rest of the column — so a strip that collapsed for an unscraped,
  /// never-played game would resize the whole view as the selection moved onto
  /// one. That is why the ROM subtitle was already a reserved line box before
  /// this, and the reservation moves onto the strip with it.
  ///
  /// It is one line rather than the details footer's two because that footer is
  /// bottom-anchored on a card and this one is a band the view has to pay for
  /// in height.
  Widget _buildIdentityBlock(BuildContext context, ColorScheme scheme) {
    // Only populated for scraped games: `GameListService` sets the flag on the
    // scraped branch alone, since a filename printed under a name derived from
    // that same filename says nothing.
    final String label = game.showRomFileNameSubtitle ? game.romname : '';

    // One fact and one marker, so no separators: the bar-separated interleave
    // this replaces existed for the rating that used to lead the line, and
    // with the rating drawn ahead of the whole block there is nothing left for
    // a bar to sit between.
    final List<Widget> strip = [
      if (label.isNotEmpty)
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.72),
              fontSize: 12.r,
              fontWeight: FontWeight.w400,
              height: 1.15,
            ),
          ),
        ),
    ];

    // The sync glyph rides at the end of the strip rather than taking a
    // segment of its own: it is a marker on the file, not another fact to
    // read, which is the same place the details footer puts it. Every "nothing
    // to say" state collapses to zero size, hence the margin on the widget
    // rather than a spacer beside it.
    if (!isFolder && system != null && syncProvider != null) {
      strip.add(
        NeoSyncStatusIcon(
          system: system!,
          game: game,
          syncProvider: syncProvider!,
          // Bare glyph at the details footer's size, not the 22.0 chip it wore
          // in the action row: a filled surface behind it is what made it read
          // as a button sitting among buttons.
          size: 16.0,
          showBackground: false,
          showGlyphShadow: false,
          margin: strip.isEmpty ? EdgeInsets.zero : EdgeInsets.only(left: 8.r),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MarqueeText(
          text: GameUtils.formatGameName(game.name),
          isActive: true,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 18.r,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(
          height: _stripHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: strip,
          ),
        ),
      ],
    );
  }
}

/// The one surface every status pill in this footer draws itself on.
///
/// [ChromeSurface] already unified the *fill*, but the rest of the pill
/// treatment stayed copy-pasted, and the drop shadows had drifted apart: 0.5 on
/// the rating and play-time pills, 0.1 on the achievements pill, none on the
/// mute pill. Because the fill is translucent by design, a shadow underneath it
/// bleeds through and darkens the body — so those three alphas rendered as
/// three visibly different pills side by side, and at 0.5 the rating pill
/// landed darker than the page background and read as pressed next to its
/// raised neighbours.
///
/// Border, radius and elevation now live here alongside the token so they
/// cannot drift again; 0.1 is the elevation the row settled on.
BoxDecoration _pillDecoration(BuildContext context) {
  final theme = Theme.of(context);
  final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
  return BoxDecoration(
    color: ChromeSurface.fill(context),
    borderRadius: radii.radiusExternal,
    border: Border.all(color: theme.colorScheme.outline, width: 1.r),
    boxShadow: [
      BoxShadow(
        color: theme.colorScheme.shadow.withValues(alpha: 0.1),
        blurRadius: 4.r,
        offset: Offset(2.0.r, 2.0.r),
      ),
    ],
  );
}

/// Height shared by every pill on the action row.
///
/// One value rather than a literal per pill: the two sit side by side, so a
/// bump to one that missed the other reads as a misaligned row rather than as
/// a bigger pill. Raised from the 32.r they were both built at — at that size
/// the readouts sat well under the 18.r name they share the footer with, and
/// the achievements pill's 8.r count was the smallest text on the screen.
double get _pillHeight => 40.r;

/// Height of the status strip under the game's name.
///
/// Fixed so the footer is the same height for every game — see
/// [GameViewFooter._buildIdentityBlock]. Driven by the tallest thing that can
/// sit on it, the 16.0 cloud-sync glyph, with a little slack above it.
double get _stripHeight => 18.r;

/// Score as a star and number, at the head of the action cluster and facing
/// the play-time clock at the other end of it.
///
/// Three homes, and the middle one is the mistake worth not repeating. It
/// started as a 32.r pill on chrome in this row; D15 took it out because the
/// row is for controls and a score answers to nothing. It then spent a while
/// as the first segment of the strip under the name, set at the strip's own
/// size — which dropped the emphasis along with the chrome and left the one
/// number people scan a list for smaller than everything around it.
///
/// The distinction D15 was reaching for is chrome, not position: a pill reads
/// as pressable and a bare glyph does not. The clock has sat in this row as a
/// bare readout since PLAY was removed and has never read as a button. So the
/// score is back in the row on the same terms — no fill, no border, 22/17
/// against the clock's 19/15 — and the two readouts bracket the pills between
/// them. The colour ramp, error at the bottom of the range and success at the
/// top, is what makes the number readable without reading it.
///
/// The pill used to reserve the width of the widest possible score so it never
/// resized between a "1" and a "10". Bare, that reservation buys nothing: the
/// cluster is right-anchored and the score is at its left edge, so a narrower
/// number only moves itself.
class _InlineRating extends StatelessWidget {
  final GameModel game;

  const _InlineRating({required this.game});

  @override
  Widget build(BuildContext context) {
    // Normalizes a 0-20 score to a 0.0-10.0 scale for color interpolation.
    final ratingValue = (game.rating / 2).clamp(0.0, 10.0);
    final colorRatio = (ratingValue - 1) / 9;
    final scheme = Theme.of(context).colorScheme;
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
        Icon(Symbols.star_rounded, color: ratingColor, size: 22.r, fill: 1),
        SizedBox(width: 4.r),
        Text(
          ratingValue.toStringAsFixed(1),
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 17.r,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
      ],
    );
  }
}

/// Accumulated play time as a clock glyph and an HH:MM:SS reading. Left the
/// action row *as a pill* for the same reason as [_InlineRating]: it reported,
/// it did not act. It sits at the end of that row again now that PLAY is gone,
/// but as this bare glyph-plus-text, never as chrome that would read as a
/// button.
///
/// Sized between the 15.r/12.r it launched at and the details footer's
/// 20.r/18.r. The small end was set against a strip of readouts it no longer
/// shares the row with, and next to the enlarged achievements pill it read as
/// a caption; the details card's size is still too much here, where the clock
/// sits under the game's own 18.r name rather than alone on artwork.
class _InlinePlayTime extends StatelessWidget {
  final GameModel game;

  const _InlinePlayTime({required this.game});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // `fill: 0` against the app-wide `IconThemeData(fill: 1.0)` in
        // `main.dart`: filled, this glyph is a solid disc with the hands
        // knocked out of it, and at 15.r on a dark band that reads as a white
        // dot rather than a clock. Filled is right for the star beside it,
        // which is a mark; this one is a diagram.
        Icon(
          Symbols.schedule_rounded,
          color: scheme.onSurface,
          size: 19.r,
          fill: 0,
        ),
        SizedBox(width: 6.r),
        // Hand-laid cells rather than `FontFeature.tabularFigures()`, which the
        // pill this replaced asked for and never got: Anta carries no `tnum`
        // table, so that feature is silently a no-op and every digit is its own
        // width.
        MonospacedClock(
          text: MonospacedClock.format(game.playTime ?? 0),
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 15.r,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
      ],
    );
  }
}

/// Compact RetroAchievements indicator reused from the details footer.
class _CompactAchievementsIndicator extends StatelessWidget {
  final GameModel game;
  final bool isLoading;
  final GameInfoAndUserProgress? gameInfo;
  final VoidCallback? onTap;

  const _CompactAchievementsIndicator({
    required this.game,
    required this.isLoading,
    this.gameInfo,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();

    // The bundled snapshot already records how many achievements a matched
    // game has, so the total needs no network call — only the user's earned
    // count does. Show it straight away instead of a spinner, and let the live
    // lookup overwrite it when it lands.
    final localTotal = game.raCoverage == RaCoverage.matched
        ? (game.raNumAchievements ?? 0)
        : 0;
    final total = gameInfo?.numAchievements ?? localTotal;
    final awarded = gameInfo?.numAwardedToUser;
    final knowsProgress = awarded != null && gameInfo != null;

    final noAchievements = !isLoading && total == 0;

    // A dash rather than a zero while the earned count is outstanding: "0/45"
    // is a claim about the user's progress that has not been fetched yet. And
    // zero only reads as "No Achievements" when RetroAchievements actually
    // answered: a ROM nothing could hash says "Unknown", the same word the
    // search screen's achievements filter files it under.
    final progressText = total > 0
        ? (knowsProgress ? '$awarded/$total' : '\u2013/$total')
        : (isLoading
              ? AppLocale.loading.getString(context)
              : raCoverageAnswersZero(game.raCoverage)
              ? AppLocale.noAchievements.getString(context)
              : AppLocale.raCoverageUnknown.getString(context));

    // Whether the earned count is still outstanding for a game that has
    // achievements to earn. The bundled snapshot gives us the total instantly,
    // so this gap is every single selection change.
    final awaitingProgress = !knowsProgress && total > 0;

    // Always determinate. This used to run an indeterminate bar through the
    // gap above, which put an orange sweep across the pill on every game the
    // user moved onto — a flash that said "working" about a lookup that
    // resolves in a moment and that the text ("-/45") already reports.
    final progress = knowsProgress && total > 0 ? awarded / total : 0.0;

    final theme = Theme.of(context);
    // Orange is for a real, known score; an empty bar that is empty only
    // because nobody has answered yet stays neutral.
    final statusColor = noAchievements || awaitingProgress
        ? theme.colorScheme.onSurface
        : Colors.orange;

    final gameIconUrl = gameInfo?.imageIcon.isNotEmpty == true
        ? 'https://media.retroachievements.org${gameInfo!.imageIcon}'
        : null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (onTap == null) return;
          SfxService().playNavSound();
          onTap!();
        },
        canRequestFocus: false,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        // Clip the ripple to the pill's own outline rather than the tighter
        // inner radius, so it doesn't square off against the rounded corners.
        borderRadius: radii.radiusExternal,
        child: Container(
          width: 126.r,
          height: _pillHeight,
          decoration: _pillDecoration(context),
          child: Padding(
            // Match the rating pill's 8.r horizontal inset so the trophy icon
            // doesn't hug the pill's left border (the pill's width above is
            // widened to 126.r to absorb the padding + the 6.r icon→text gap
            // without squeezing the 70.r text/progress column).
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: radii.radiusInternal,
                  child: Container(
                    width: 28.r,
                    height: 28.r,
                    color: theme.colorScheme.surface,
                    child: gameIconUrl != null
                        ? Image.network(
                            gameIconUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Icon(
                              Symbols.emoji_events_rounded,
                              color: statusColor,
                              size: 15.r,
                            ),
                          )
                        : Icon(
                            Symbols.emoji_events_rounded,
                            color: statusColor,
                            size: 15.r,
                          ),
                  ),
                ),
                SizedBox(width: 6.r),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 70.r,
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
                    SizedBox(height: 2.r),
                    // Bar is deliberately narrower than the 70.r text row so it
                    // doesn't run to the pill's right edge — leaves a right
                    // margin under the progress count.
                    SizedBox(
                      width: 58.r,
                      child: ClipRRect(
                        borderRadius: radii.radiusInternal,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4.5.r,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Select-tap hint + current sound state for the preview video, tappable for
/// touchscreen users. Watches the config provider on its own so the memoized
/// footer instance around it never has to rebuild when sound is toggled.
class _MuteHintPill extends StatelessWidget {
  final VoidCallback onToggleMute;

  const _MuteHintPill({required this.onToggleMute});

  @override
  Widget build(BuildContext context) {
    final radii = Theme.of(context).extension<CornerRadii>() ?? CornerRadii.m();
    final scheme = Theme.of(context).colorScheme;

    return Selector<SqliteConfigProvider, bool>(
      selector: (_, provider) => !provider.config.videoSound,
      builder: (context, isMuted, _) {
        // Structured like the achievements pill — transparent Material for the
        // ink, decoration on the Container — so both resolve to the same fill.
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              SfxService().playNavSound();
              onToggleMute();
            },
            canRequestFocus: false,
            borderRadius: radii.radiusExternal,
            child: Container(
              height: _pillHeight,
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
              decoration: _pillDecoration(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/gamepad/Xbox_View_button.png',
                    width: 19.r,
                    height: 19.r,
                    color: scheme.onSurface,
                  ),
                  SizedBox(width: 4.r),
                  Icon(
                    isMuted
                        ? Symbols.volume_off_rounded
                        : Symbols.volume_up_rounded,
                    size: 19.r,
                    color: scheme.onSurface,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
