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
import 'package:neostation/widgets/monospaced_clock.dart';

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

  Future<void> pumpFooter(
    WidgetTester tester, {
    GameModel? game,
    bool showsPill = false,
    bool canRandom = true,
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
                        onPlayGame: () => pressed.add('play'),
                        onShowRandomGame: canRandom
                            ? () => pressed.add('random')
                            : null,
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

  testWidgets('the readouts lead the row and the controls close it', (
    tester,
  ) async {
    await pumpFooter(tester, showsPill: true);

    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final trophy = tester.getRect(find.byIcon(Symbols.emoji_events_rounded));
    final clock = tester.getRect(find.byType(MonospacedClock));
    final play = tester.getRect(find.text('PLAY'));

    expect(star.right, lessThanOrEqualTo(trophy.left));
    expect(trophy.right, lessThanOrEqualTo(clock.left));
    expect(clock.right, lessThanOrEqualTo(play.left));

    // One row: everything on it shares a centre line.
    for (final other in [trophy, clock, play]) {
      expect(
        star.center.dy,
        moreOrLessEquals(other.center.dy, epsilon: 2.0),
        reason: 'one row, not a stack',
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

    await tester.tap(find.byIcon(Symbols.casino_rounded));
    await tester.tap(find.byIcon(Symbols.favorite_rounded));
    await tester.tap(find.byIcon(Symbols.settings_rounded));
    await tester.tap(find.text('PLAY'));

    expect(pressed, ['random', 'favorite', 'settings', 'play']);
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

  testWidgets('a host with no random dialog gets no button for one', (
    tester,
  ) async {
    await pumpFooter(tester, canRandom: false);

    expect(find.byIcon(Symbols.casino_rounded), findsNothing);
    // The rest of the row is untouched by its absence.
    expect(find.byIcon(Symbols.favorite_rounded), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);
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
