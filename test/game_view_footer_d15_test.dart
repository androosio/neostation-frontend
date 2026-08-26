import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/game_view_footer.dart';
import 'package:neostation/widgets/monospaced_clock.dart';

/// D15 — the grid/carousel footer's action row is controls only, and the
/// readouts that used to sit in it live on the status strip under the game's
/// name instead.
///
/// Two separable claims, and the second one is the one that bites: the strip is
/// conditional (a game may have no score and may never have been played) but
/// this footer's height is *paid for by the view above it* — the grid and the
/// carousel take whatever column space is left. A strip that collapsed for an
/// unscraped game would resize the whole grid as the selection moved onto one.
class _FakeRaProvider extends RetroAchievementsProvider {
  @override
  bool get isConnected => false;
}

GameModel _game({double rating = 0, int? playTime, bool subtitle = true}) =>
    GameModel(
      romname: 'Sonic The Hedgehog.gg',
      realname: 'Sonic The Hedgehog',
      name: 'Sonic The Hedgehog',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: rating,
      playTime: playTime,
      showRomFileNameSubtitle: subtitle,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  Future<void> pumpFooter(WidgetTester tester, GameModel game) async {
    // The footer lays out against the full window width in the real app; give
    // the test the same room or its Row overflows.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<RetroAchievementsProvider>.value(
        value: _FakeRaProvider(),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: ThemeData(extensions: [ChromeSurface.standard()]),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              // Top-left aligned so the footer is measured at the height it
              // actually wants, rather than being stretched to the body's.
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 1280,
                  child: GameViewFooter(game: game, onPlay: () {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the rating and the clock are not in the action row', (
    tester,
  ) async {
    await pumpFooter(tester, _game(rating: 16.0, playTime: 3671));

    // Both readouts render...
    expect(find.byIcon(Symbols.star_rounded), findsOneWidget);
    expect(find.byType(MonospacedClock), findsOneWidget);

    // ...but neither is inside the action cluster, which the footer wraps in
    // an ExcludeFocus because everything in it is pressable.
    final actionRow = find.byType(ExcludeFocus);
    expect(actionRow, findsOneWidget);
    expect(
      find.descendant(
        of: actionRow,
        matching: find.byIcon(Symbols.star_rounded),
      ),
      findsNothing,
      reason: 'a score answers to nothing; it does not belong among controls',
    );
    expect(
      find.descendant(of: actionRow, matching: find.byType(MonospacedClock)),
      findsNothing,
      reason: 'the play-time clock reports, it does not act',
    );
  });

  testWidgets('the clock is laid out in hand-made cells, not tabular figures', (
    tester,
  ) async {
    await pumpFooter(tester, _game(playTime: 3671));

    // 01:01:11 — every glyph in its own fixed-width cell.
    expect(find.text('0'), findsNWidgets(2));
    expect(find.text('1'), findsNWidgets(4));
    expect(find.text(':'), findsNWidgets(2));
  });

  testWidgets('the footer is the same height with and without the readouts', (
    tester,
  ) async {
    // Nothing at all on the strip: unscraped (so no filename either), never
    // played, no score.
    await pumpFooter(tester, _game(subtitle: false));
    final bare = tester.getSize(find.byType(GameViewFooter));

    await pumpFooter(tester, _game(rating: 16.0, playTime: 3671));
    final populated = tester.getSize(find.byType(GameViewFooter));

    expect(
      populated.height,
      bare.height,
      reason:
          'the grid takes the column space this footer leaves, so a strip that '
          'collapsed for an unscraped game would resize the whole view as the '
          'selection moved onto one',
    );
  });
}
