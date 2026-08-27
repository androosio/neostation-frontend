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
import 'package:neostation/widgets/marquee_text.dart';

/// What the grid and carousel footer paints on its bare text and glyphs.
///
/// Both claims here are removals of something that shipped and looked wrong,
/// so both are worth holding down.
///
/// The halo: the footer floats over the grid's scrolling rows, and for two
/// commits it carried a halo so the text survived the box art passing behind
/// it. The scrim came back instead, finishing opaque in the band the text sits
/// in, and the halo was painted in the background's own colour -- the same
/// colour the scrim now lays down there, so it could only converge on what was
/// already behind it. The carousel never had the problem at all: its cards
/// stop where its footer starts.
///
/// The clock: the app sets `IconThemeData(fill: 1.0)` globally, and a filled
/// `schedule_rounded` is a solid disc with the hands knocked out of it, which
/// at footer size reads as a white dot rather than a clock.

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

    testWidgets('the name carries no shadows in the $label theme', (
      tester,
    ) async {
      await pumpFooter(tester, plain(brightness));

      // Not "no black shadow" but no shadow at all: the halo this replaced was
      // scheme-coloured and still wrong, because the scrim behind the band is
      // that same colour.
      expect(nameStyle(tester).shadows ?? const <Shadow>[], isEmpty);
    });
  }

  testWidgets('the clock glyph is a clock, not a filled disc', (tester) async {
    await pumpFooter(tester, plain(Brightness.dark));

    final icon = tester.widget<Icon>(find.byIcon(Symbols.schedule_rounded));
    expect(
      icon.fill,
      0,
      reason:
          'the app-wide IconThemeData sets fill 1.0, and this glyph filled is '
          'a solid disc with the hands knocked out of it',
    );
  });

  testWidgets('the reading keeps its hours even at an hour and change', (
    tester,
  ) async {
    // Zero-padded HH:MM:SS whatever the value: the reading is right-aligned at
    // the end of the row, so a segment that appeared as the clock rolled over
    // would resize it under a selection that had not moved.
    await pumpFooter(tester, plain(Brightness.dark));

    final digits = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    // The clock is laid out a character to a cell, so it reaches the tree as
    // its glyphs rather than as one string.
    expect(digits.join().contains('01:01:11'), isTrue);
  });
}
