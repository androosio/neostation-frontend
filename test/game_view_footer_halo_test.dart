import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/game_view_footer.dart';
import 'package:neostation/widgets/marquee_text.dart';

/// The grid's footer floats over its scrolling rows with no scrim, so box art
/// passes directly behind the game's name and the strip under it. The text
/// therefore has to carry its own background separation.
///
/// The claim under test is not "there are shadows" but *which* shadows. The
/// details-card footer this one mirrors uses a fixed black drop shadow, which
/// works only because that footer always paints onto dark fanart; copied here
/// it renders as ghost text in the light theme, which is why this footer
/// dropped shadows entirely in the first place. The halo has to come from the
/// scheme so it is always the opposite of the fill in front of it.
class _FakeRaProvider extends RetroAchievementsProvider {
  @override
  bool get isConnected => false;
}

GameModel _game() => GameModel(
  romname: 'Sonic The Hedgehog.gg',
  realname: 'Sonic The Hedgehog',
  name: 'Sonic The Hedgehog',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 16.0,
  playTime: 3671,
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

  Future<ColorScheme> pumpFooter(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final theme = ThemeData(
      brightness: brightness,
      extensions: [ChromeSurface.standard()],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<RetroAchievementsProvider>.value(
        value: _FakeRaProvider(),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: theme,
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 1280,
                  child: GameViewFooter(game: _game()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return theme.colorScheme;
  }

  /// The game's name, which is the thing the report was actually about.
  TextStyle nameStyle(WidgetTester tester) =>
      tester.widget<MarqueeText>(find.byType(MarqueeText)).style!;

  for (final brightness in Brightness.values) {
    final label = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('the name carries a halo in the $label theme', (tester) async {
      final scheme = await pumpFooter(tester, brightness);
      final shadows = nameStyle(tester).shadows;

      expect(
        shadows,
        isNotEmpty,
        reason:
            'the footer floats over the scrolling rows: without a halo the '
            'name is read against whatever box art is passing behind it',
      );
      expect(
        shadows!.every((s) => s.color == scheme.surface),
        isTrue,
        reason:
            'the halo is the surface the text sits on, so it is always '
            'the opposite of the onSurface fill in front of it',
      );
      // Zero offset: this separates the glyph from its background on every
      // side, rather than casting it in one direction like a drop shadow.
      expect(shadows.every((s) => s.offset == Offset.zero), isTrue);
    });
  }

  testWidgets('the light theme does not inherit the details card\'s black '
      'drop shadow', (tester) async {
    await pumpFooter(tester, Brightness.light);

    // The regression this guards: a black shadow behind near-black text on a
    // light background is invisible, and it was invisible in exactly the way
    // that made this footer drop its shadows to begin with.
    expect(
      nameStyle(tester).shadows!.any((s) => s.color == Colors.black),
      isFalse,
    );
  });
}
