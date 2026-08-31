import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';

/// The details card's footer is one row: the readouts on the left, the
/// controls on the right, and nothing above it.
///
/// It got there by losing two text lines. The metadata strip (players,
/// publisher, year, genre) was painting scraped facts onto the game's fanart
/// that the info tab is the place for, and the filename under it went with it;
/// the cloud-sync glyph that rode at the end of that line is a chip in the row
/// now. What is left is pinned here because each piece has been moved before:
///
///  * The score has been in three places — a pill in this row, a segment of
///    the metadata marquee (where a long publisher could scroll it out of
///    sight), and now a bare readout at the row's head.
///  * PLAY was removed as a third route to something A and a double tap
///    already did. It is back because the rail that carried every *other*
///    touch affordance was removed too, which left touch with one pressable
///    thing in the whole view.
///  * The row's height is the load-bearing claim: it no longer depends on what
///    the selected game carries, so nothing in the footer moves as the cursor
///    walks a list of scraped and unscraped, matched and unmatched games.
class _StubSync implements ISyncProvider {
  @override
  bool get isAuthenticated => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RaProvider extends RetroAchievementsProvider {
  _RaProvider(this._connected);

  final bool _connected;

  @override
  bool get isConnected => _connected;
}

SystemModel _system() => const SystemModel(
  folderName: 'psx',
  realName: 'Sony PlayStation',
  iconImage: '',
  color: '#FFFFFF',
);

GameModel _game({
  double rating = 18.0,
  int? playTime = 3671,
  bool isFavorite = false,
}) => GameModel(
  romname: 'A Game (USA).chd',
  realname: 'A Game',
  name: 'A Game',
  year: '1999',
  developer: '',
  publisher: 'Sony',
  genre: 'RPG',
  players: '1',
  rating: rating,
  playTime: playTime,
  isFavorite: isFavorite,
  showRomFileNameSubtitle: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // No audio engine in a widget test, and every control on this row plays a
    // sound on tap.
    SfxService().setEnabled(false);
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  late List<String> pressed;

  setUp(() => pressed = <String>[]);

  /// The details card's own width, not the screen's. On a 1920-wide handheld
  /// the sidebar takes the first third, which leaves the card ~435 of the
  /// footer's design units -- the width the row actually has to fit in.
  const double handheldCardWidth = 435;

  Future<void> pumpFooter(
    WidgetTester tester, {
    GameModel? game,
    bool showsPill = false,
    double width = 640,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<RetroAchievementsProvider>.value(
        value: _RaProvider(showsPill),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              extensions: [ChromeSurface.standard()],
            ),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 360,
                  child: Stack(
                    children: [
                      GameDetailsFooter(
                        system: _system(),
                        game: game ?? _game(),
                        isMusicSystem: false,
                        hasScreenScraper: false,
                        isSecondaryScreenActive: false,
                        cloudSyncEnabled: false,
                        syncProvider: _StubSync(),
                        onShowAchievements: () {},
                        hasRetroAchievements: showsPill,
                        // Loading is the cheapest state that makes the pill
                        // render without a fixture of achievement data.
                        isLoadingAchievements: showsPill,
                        onPlayGame: () => pressed.add('play'),
                        onToggleFavorite: () => pressed.add('favorite'),
                        onOpenGameSettings: () => pressed.add('settings'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the scraped facts are not on the footer at all', (tester) async {
    await pumpFooter(tester);

    // Publisher, year, genre and the ROM filename all belong to the info tab
    // now; painting them on the artwork here was the duplicate.
    expect(find.text('Sony'), findsNothing);
    expect(find.text('1999'), findsNothing);
    expect(find.text('RPG'), findsNothing);
    expect(find.text('A Game (USA).chd'), findsNothing);
  });

  testWidgets('the score reads to one decimal, so a half point survives', (
    tester,
  ) async {
    // 17/20 is 8.5, and rounding it to a whole number threw away the only
    // thing that distinguished it from a 16 or an 18.
    await pumpFooter(tester, game: _game(rating: 17.0));
    expect(find.text('8.5'), findsOneWidget);

    await pumpFooter(tester, game: _game(rating: 16.0));
    expect(find.text('8.0'), findsOneWidget);
  });

  testWidgets('the score leads the row and the controls close it', (
    tester,
  ) async {
    await pumpFooter(tester, showsPill: true);

    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final trophy = tester.getRect(find.byIcon(Symbols.emoji_events_rounded));
    final heart = tester.getRect(find.byIcon(Symbols.favorite_rounded));
    final play = tester.getRect(find.text('PLAY'));

    expect(star.right, lessThanOrEqualTo(trophy.left));
    expect(trophy.right, lessThanOrEqualTo(heart.left));
    expect(heart.right, lessThanOrEqualTo(play.left));

    // One row: everything on it shares a centre line.
    for (final other in [trophy, heart, play]) {
      expect(
        star.center.dy,
        moreOrLessEquals(other.center.dy, epsilon: 2.0),
        reason: 'one row, not a stack',
      );
    }
  });

  testWidgets('the play-time clock is not on this row', (tester) async {
    // It was the last inert readout left among the controls. The score earns
    // its place by being what a list is scanned for; a running total of hours
    // is not, and the row it was crowding is the only touch surface the view
    // has.
    await pumpFooter(tester, game: _game(playTime: 3671));

    expect(find.byIcon(Symbols.schedule_rounded), findsNothing);
    expect(find.textContaining('01:01'), findsNothing);
  });

  testWidgets('the icon buttons are circles and PLAY is not', (tester) async {
    // Everything on the row wears the same chip, fully rounded, so the square
    // controls come out as circles and the wider ones as stadiums -- that is
    // what makes the row read as one set rather than a strip of tiles, and it
    // does not follow the theme's corner style to get there: that is for
    // panels and cards. PLAY keeps the theme's corner precisely so it stays
    // out of the set; it is the row's primary action, not one more chip in it.
    await pumpFooter(tester, showsPill: true);

    for (final finder in [
      // The score chip, by the star inside it.
      find.byIcon(Symbols.star_rounded),
      find.byIcon(Symbols.favorite_rounded),
      find.byIcon(Symbols.settings_rounded),
    ]) {
      final chip = _decoratedAncestor(tester, finder);
      expect(
        _radiusOf(chip),
        greaterThanOrEqualTo(chip.size!.height / 2),
        reason: 'fully rounded, not a rounded square',
      );
    }

    final play = _decoratedAncestor(tester, find.text('PLAY'));
    expect(
      _radiusOf(play),
      lessThan(play.size!.height / 2),
      reason: 'squarer than the chips beside it, not a stadium',
    );
  });

  testWidgets('the score wears the same chip as the controls', (tester) async {
    // A row of chips with one bare readout floating at its head did not read
    // as "that one is not pressable", it read as unfinished. What keeps the
    // score out of the control set is that its chip has no ink and no tap
    // target, not that it has no chrome.
    await pumpFooter(tester);

    final score = _decoratedAncestor(tester, find.byIcon(Symbols.star_rounded));
    final gear = _decoratedAncestor(
      tester,
      find.byIcon(Symbols.settings_rounded),
    );

    expect(
      (score.widget as Container).decoration,
      isA<BoxDecoration>().having(
        (d) => d.color,
        'fill',
        ((gear.widget as Container).decoration as BoxDecoration).color,
      ),
    );
    expect(score.size!.height, gear.size!.height);
  });

  testWidgets('the pill keeps a usable share on a handheld-sized card', (
    tester,
  ) async {
    // The bug this pins: the pill is the row's only Expanded, so it is handed
    // whatever the fixed items leave and has no floor of its own. On the Thor
    // those items came to more than the card was wide, and the pill rendered
    // 7px across -- full height, right shape, none of its contents, and no
    // overflow banner to say so. Sizing the row is what buys the share back,
    // so the budget has to be pinned at the width it broke on.
    await pumpFooter(tester, showsPill: true, width: handheldCardWidth);

    expect(find.byIcon(Symbols.emoji_events_rounded), findsOneWidget);

    final pill = _decoratedAncestor(
      tester,
      find.byIcon(Symbols.emoji_events_rounded),
    );
    expect(
      pill.size!.width,
      greaterThanOrEqualTo(78.0),
      reason: 'the icon, the count and a bar with somewhere to fill',
    );
  });

  testWidgets('a card too narrow for the pill gets no pill, not a splinter', (
    tester,
  ) async {
    // 380 is inside the one window where this decision is live: the fixed
    // items still fit (below ~346 the row overflows outright, which no real
    // card is narrow enough to reach) but what they leave is under the pill's
    // floor.
    await pumpFooter(tester, showsPill: true, width: 380);

    expect(
      find.byIcon(Symbols.emoji_events_rounded),
      findsNothing,
      reason: 'omitted outright rather than drawn as a dark sliver',
    );
    // The rest of the row is unaffected: the controls are what the row is for.
    expect(find.text('PLAY'), findsOneWidget);
    expect(find.byIcon(Symbols.settings_rounded), findsOneWidget);
  });

  testWidgets('the score chip is the same width whatever the score', (
    tester,
  ) async {
    // The number runs from "0.1" to "10.0", and the achievements pill beside
    // it is the row's only Expanded -- so a chip that sized to its content
    // handed the pill a different width on every game, and on a 10.0 game it
    // pushed the pill under its floor and off the row entirely.
    final widths = <double>{};
    final pillWidths = <double>{};
    for (final rating in [0.1, 16.0, 17.0, 20.0]) {
      await pumpFooter(
        tester,
        showsPill: true,
        width: handheldCardWidth,
        game: _game(rating: rating),
      );
      widths.add(
        _decoratedAncestor(
          tester,
          find.byIcon(Symbols.star_rounded),
        ).size!.width,
      );
      pillWidths.add(
        _decoratedAncestor(
          tester,
          find.byIcon(Symbols.emoji_events_rounded),
        ).size!.width,
      );
    }

    expect(widths, hasLength(1), reason: 'one footprint for every score');
    expect(
      pillWidths,
      hasLength(1),
      reason: 'so the pill does not resize as the cursor walks the list',
    );
  });

  testWidgets('the score chip is inset optically, not geometrically', (
    tester,
  ) async {
    // Guard against this being "tidied" back to a symmetric inset. Measured on
    // device, the star's ink sits about 9px inside its icon box while the
    // number's last digit runs nearly to the edge of its own, so equal insets
    // put the group 5px right of where it looks centred. The widget rects are
    // symmetric to the decimal either way, which is exactly why the imbalance
    // survived until someone looked at the pixels.
    await pumpFooter(tester, width: handheldCardWidth);

    final chip = _chipRect(tester, find.byIcon(Symbols.star_rounded));
    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final number = tester.getRect(find.text('9.0'));

    expect(
      star.left - chip.left,
      lessThan(chip.right - number.right),
      reason: 'the star side is tighter, to pay for the ink inside its box',
    );
  });

  testWidgets('the row is evenly spaced', (tester) async {
    // It was 8 either side of the pill and 6 between the buttons, which reads
    // as unevenly spaced rather than as a rhythm.
    await pumpFooter(tester, showsPill: true, width: handheldCardWidth);

    final rects = [
      for (final finder in [
        find.byIcon(Symbols.star_rounded),
        find.byIcon(Symbols.emoji_events_rounded),
        find.byIcon(Symbols.favorite_rounded),
        find.byIcon(Symbols.settings_rounded),
        find.text('PLAY'),
      ])
        _chipRect(tester, finder),
    ];

    final gaps = [
      for (int i = 1; i < rects.length; i++) rects[i].left - rects[i - 1].right,
    ];

    for (final gap in gaps) {
      expect(
        gap,
        moreOrLessEquals(gaps.first, epsilon: 0.5),
        reason: 'one gap between every pair, got $gaps',
      );
    }
  });

  testWidgets('the row is the same height whatever the game carries', (
    tester,
  ) async {
    // The four states that each used to resize this footer: a pill or none, a
    // score or none, a clock or none, and the metadata strip an unscraped game
    // never had.
    await pumpFooter(tester, showsPill: true);
    final withPill = tester.getSize(find.byType(GameDetailsFooter));

    await pumpFooter(tester);
    final noPill = tester.getSize(find.byType(GameDetailsFooter));

    await pumpFooter(tester, game: _game(rating: 0, playTime: null));
    final bare = tester.getSize(find.byType(GameDetailsFooter));

    expect(noPill.height, withPill.height);
    expect(bare.height, withPill.height);
  });

  testWidgets('every control is a touch route to what the pad already does', (
    tester,
  ) async {
    await pumpFooter(tester);

    await tester.tap(find.byIcon(Symbols.favorite_rounded));
    await tester.tap(find.byIcon(Symbols.settings_rounded));
    await tester.tap(find.text('PLAY'));

    expect(pressed, ['favorite', 'settings', 'play']);
  });

  testWidgets('the heart reports the flag it toggles', (tester) async {
    await pumpFooter(tester);
    expect(
      tester.widget<Icon>(find.byIcon(Symbols.favorite_rounded)).fill,
      0,
      reason: 'an outline on a game that is not a favourite',
    );

    await pumpFooter(tester, game: _game(isFavorite: true));
    expect(
      tester.widget<Icon>(find.byIcon(Symbols.favorite_rounded)).fill,
      1,
      reason: 'filled once it is one, so the toggle reads without a press',
    );
  });

  testWidgets('the row carries no readout that only reports', (tester) async {
    // Two chips came off this row to pay for the achievements pill's width,
    // and both were about something other than acting on the selected game:
    // the cloud-sync glyph reported state (and is on the grid/carousel footer
    // anyway), and Random is a view-level action rather than one about this
    // game. Random is still on the Y menu.
    await pumpFooter(tester);

    expect(find.byIcon(Symbols.casino_rounded), findsNothing);
    expect(find.byIcon(Symbols.cloud_rounded), findsNothing);
    expect(find.byIcon(Symbols.cloud_off_rounded), findsNothing);
    expect(find.byIcon(Symbols.cloud_done_rounded), findsNothing);
  });

  testWidgets('nothing on the row can take the gamepad cursor', (tester) async {
    // The card owns no focusable widgets: the list beside it drives selection,
    // and a second cursor inside the card would fight it.
    await pumpFooter(tester, showsPill: true);

    expect(find.byType(ExcludeFocus), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ExcludeFocus),
        matching: find.text('PLAY'),
      ),
      findsOneWidget,
    );
  });
}

/// The nearest ancestor of [of] that actually draws a chip. The `Container`s
/// further out are the footer's own padding boxes and carry no decoration.
Element _decoratedAncestor(WidgetTester tester, Finder of) => find
    .ancestor(of: of, matching: find.byType(Container))
    .evaluate()
    .firstWhere((e) => (e.widget as Container).decoration is BoxDecoration);

double _radiusOf(Element chip) =>
    (((chip.widget as Container).decoration as BoxDecoration).borderRadius
            as BorderRadius)
        .topLeft
        .x;

/// The on-screen rectangle of the chip [of] sits inside.
Rect _chipRect(WidgetTester tester, Finder of) {
  final box = _decoratedAncestor(tester, of).renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}
