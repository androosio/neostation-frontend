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
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/scrolling_status_line.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/monospaced_clock.dart';

/// Where the score lives on the details card's footer, and why it is not a
/// detail that can be left to drift.
///
/// It has been in three places. A 45.r pill *in* the bottom row, which D15
/// removed because that row is for controls and a score answers to nothing.
/// Then a segment of the metadata marquee, which cost it the emphasis along
/// with the chrome and let it scroll out of sight behind a long publisher.
/// Now back on the bottom row, but as a bare readout facing the play-time
/// clock at the other end, with the achievements pill between them.
///
/// The claim that binds the layout together is that both readouts are
/// *anchored*: each sits at a fixed distance from its own edge of the card
/// whatever else is on the row, so neither moves as the selection walks a list
/// of matched and unmatched games.
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

GameModel _game({double rating = 18.0, int? playTime = 3671}) => GameModel(
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
  showRomFileNameSubtitle: true,
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

  Future<void> pumpFooter(
    WidgetTester tester, {
    GameModel? game,
    bool showsPill = false,
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
                  width: 640,
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

  testWidgets('the score is off the metadata strip entirely', (tester) async {
    await pumpFooter(tester);

    expect(find.byIcon(Symbols.star_rounded), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ScrollingStatusLine),
        matching: find.byIcon(Symbols.star_rounded),
      ),
      findsNothing,
      reason:
          'on the marquee it could scroll out of sight behind a long publisher',
    );

    // Let the marquees' timers expire so none outlives the test.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the score is on the last row, left of the achievements pill', (
    tester,
  ) async {
    await pumpFooter(tester, showsPill: true);

    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final pill = tester.getRect(find.byType(ExcludeFocus));
    final filename = tester.getRect(find.text('A Game (USA).chd'));

    expect(
      star.right,
      lessThanOrEqualTo(pill.left),
      reason: 'left of the cheevos button, not above it',
    );
    expect(
      star.center.dy,
      greaterThan(filename.center.dy),
      reason: 'the last row, below both text lines',
    );

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the two readouts take opposite ends of that row', (
    tester,
  ) async {
    await pumpFooter(tester, showsPill: true);

    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final clock = tester.getRect(find.byType(MonospacedClock));

    expect(star.right, lessThan(clock.left));
    expect(
      star.center.dy,
      moreOrLessEquals(clock.center.dy, epsilon: 2.0),
      reason: 'one row, not a score above a clock',
    );

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a score alone holds the last row open', (tester) async {
    // No pill and no clock: without this, the row would collapse and the score
    // would have nowhere anchored to sit. It is the same claim the clock has
    // had since D25, and the score inherits it by being the row's other end.
    await pumpFooter(tester, game: _game(playTime: null));
    final scored = tester.getSize(find.byType(GameDetailsFooter));
    await tester.pump(const Duration(seconds: 5));

    await pumpFooter(tester, game: _game(rating: 0));
    final clocked = tester.getSize(find.byType(GameDetailsFooter));
    await tester.pump(const Duration(seconds: 5));

    expect(
      scored.height,
      clocked.height,
      reason:
          'a game with only a score and one with only a clock get the same row',
    );
  });
}
