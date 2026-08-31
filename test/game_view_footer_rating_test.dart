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

/// The score is its own element, at the head of the footer's action cluster.
///
/// Losing the *pill* (D15) was right — it showed a number and answered to
/// nothing — but it was exiled from the row along with it, and landed as one
/// more segment of the strip under the game's name at the strip's own size.
/// That dropped the emphasis with the chrome: the one number people scan a
/// list for ended up the smallest thing in the footer, behind the name and
/// sharing a line with the filename.
///
/// It is back in the row as a bare readout, at the end opposite the clock,
/// which is the same shape the details card's bottom row has.
class _FakeRaProvider extends RetroAchievementsProvider {
  @override
  bool get isConnected => false;
}

GameModel _game({double rating = 0}) => GameModel(
  romname: 'Sonic The Hedgehog.gg',
  realname: 'Sonic The Hedgehog',
  name: 'Sonic The Hedgehog',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: rating,
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

  Future<void> pumpFooter(WidgetTester tester, GameModel game) async {
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
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 1280, child: GameViewFooter(game: game)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the score is in the action cluster, not on the strip', (
    tester,
  ) async {
    await pumpFooter(tester, _game(rating: 16.0));

    expect(
      find.descendant(
        of: find.byType(ExcludeFocus),
        matching: find.byIcon(Symbols.star_rounded),
      ),
      findsOneWidget,
    );

    // Which puts it past the name rather than under it — on the strip it was
    // the filename's neighbour and could be crowded by one.
    final star = tester.getRect(find.byIcon(Symbols.star_rounded));
    final name = tester.getRect(find.byType(MarqueeText));
    expect(star.left, greaterThan(name.left));
    expect(
      star.center.dy,
      lessThan(tester.getRect(find.text('Sonic The Hedgehog.gg')).center.dy),
      reason: 'the cluster is centred on the footer, above the strip line',
    );
  });

  testWidgets('the score outweighs the strip it left', (tester) async {
    await pumpFooter(tester, _game(rating: 16.0));

    final score = tester.widget<Text>(find.text('8.0'));
    final filename = tester.widget<Text>(find.text('Sonic The Hedgehog.gg'));

    expect(score.style!.fontSize, greaterThan(filename.style!.fontSize!));
    expect(
      tester.widget<Icon>(find.byIcon(Symbols.star_rounded)).size,
      greaterThan(score.style!.fontSize!),
    );
  });

  testWidgets('an unscored game leaves no star and no hole', (tester) async {
    await pumpFooter(tester, _game(rating: 16.0));
    final scored = tester.getRect(find.byType(ExcludeFocus));

    await pumpFooter(tester, _game());
    final unscored = tester.getRect(find.byType(ExcludeFocus));

    expect(find.byIcon(Symbols.star_rounded), findsNothing);
    expect(
      unscored.right,
      moreOrLessEquals(scored.right, epsilon: 0.5),
      reason:
          'the cluster is right-anchored, so a missing score narrows it rather '
          'than leaving a reserved slot at its head',
    );
    expect(unscored.width, lessThan(scored.width));
  });
}
