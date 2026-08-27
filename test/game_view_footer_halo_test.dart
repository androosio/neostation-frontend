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
import 'package:neostation/themes/tokyo_night_theme.dart';
import 'package:neostation/widgets/game_view_footer.dart';
import 'package:neostation/widgets/marquee_text.dart';

/// The grid's footer floats over its scrolling rows, so box art passes directly
/// behind the game's name and the strip under it. The text carries a halo so it
/// survives that.
///
/// The claim under test is not "there are shadows" but *which* shadows, because
/// every way of getting this wrong still produces shadows. The details-card
/// footer this one mirrors uses a fixed black drop shadow, which works only
/// because that footer always paints onto dark fanart; copied here it is ghost
/// text in the light theme. And `colorScheme.surface` is not the colour behind
/// this footer either — the grid sits on `scaffoldBackgroundColor`, a different
/// colour in every bundled theme.
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

  Future<ThemeData> pumpFooter(WidgetTester tester, ThemeData theme) async {
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
    return theme;
  }

  ThemeData plain(Brightness brightness) =>
      ThemeData(brightness: brightness, extensions: [ChromeSurface.standard()]);

  /// The game's name, which is the thing the report was actually about.
  TextStyle nameStyle(WidgetTester tester) =>
      tester.widget<MarqueeText>(find.byType(MarqueeText)).style!;

  for (final brightness in Brightness.values) {
    final label = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('the name carries a halo in the $label theme', (tester) async {
      final theme = await pumpFooter(tester, plain(brightness));
      final shadows = nameStyle(tester).shadows;

      expect(
        shadows,
        isNotEmpty,
        reason:
            'the footer floats over the scrolling rows: without a halo the '
            'name is read against whatever box art is passing behind it',
      );
      expect(
        shadows!.every((s) => s.color == theme.scaffoldBackgroundColor),
        isTrue,
        reason:
            'the halo is the background the footer floats on, so it is always '
            'the opposite of the onSurface fill in front of it',
      );
    });
  }

  testWidgets('the light theme does not inherit the black drop shadow', (
    tester,
  ) async {
    await pumpFooter(tester, plain(Brightness.light));

    // A black shadow behind near-black text on a light background is
    // invisible, and it was invisible in exactly the way that made this footer
    // drop its shadows to begin with.
    expect(
      nameStyle(tester).shadows!.any((s) => s.color == Colors.black),
      isFalse,
    );
  });

  testWidgets('the halo tracks the scaffold background, not the surface', (
    tester,
  ) async {
    // A bundled theme, chosen because it is one of the many where those two
    // colours genuinely differ: surface is 0xFF24283B, the scaffold the grid
    // actually sits on is 0xFF1A1B26. Painting the halo in `surface` was
    // therefore both too light to separate the text from bright box art and
    // faintly visible as a plate against the flat background it was meant to
    // vanish into.
    final theme = await pumpFooter(tester, tokyoNightTheme);
    expect(
      theme.scaffoldBackgroundColor,
      isNot(theme.colorScheme.surface),
      reason: 'the fixture proves nothing if the two agree in this theme',
    );

    final shadows = nameStyle(tester).shadows!;
    expect(
      shadows.every((s) => s.color == theme.scaffoldBackgroundColor),
      isTrue,
    );
    expect(shadows.any((s) => s.color == theme.colorScheme.surface), isFalse);
  });

  testWidgets('the halo separates the glyph on every side', (tester) async {
    await pumpFooter(tester, tokyoNightTheme);
    final shadows = nameStyle(tester).shadows!;

    // A ring of offsets rather than a single drop shadow: text over box art has
    // no reliable light direction, so any edge left un-ringed is an edge read
    // straight against the artwork.
    final ring = shadows.where((s) => s.offset != Offset.zero);
    expect(ring.map((s) => s.offset.dx.sign).toSet(), {-1.0, 1.0});
    expect(ring.map((s) => s.offset.dy.sign).toSet(), {-1.0, 1.0});
    // Plus wide passes under the ring, reaching further out than it can.
    expect(shadows.where((s) => s.offset == Offset.zero), isNotEmpty);
  });
}
