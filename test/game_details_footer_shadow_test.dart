import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// The details card footer paints its two text lines straight onto the game's
/// fanart, so both carry a drop shadow, and both marquee when they are wider
/// than the card. That combination is where a bug lived that no local gate
/// could see: the filename scrolled out from under its own shadow and left it
/// standing, on device only.
///
/// Two causes, and this file holds both down because both look like tidiness
/// to the next person reading that file:
///
///  1. A `RepaintBoundary` around text a marquee translates. It reads as free
///     performance — the footer rebuilds on every sync tick and every
///     achievements poll — but a retained layer is *repositioned* rather than
///     repainted, and the damage the engine works out for that move is the
///     layer's paint bounds. For a `Text` that is its line box, and the shadow
///     hangs outside it, so on a partial-repaint frame the shadow's pixels are
///     neither cleared where they were nor drawn where they now belong.
///  2. The clip. `ScrollingStatusLine.shadowRoom` exists only for these two
///     lines; a footer that stopped passing it would cut the bottom off both
///     shadows the moment either line was long enough to scroll.
///
/// Neither shows up in a screenshot, and neither shows up on a desktop build.

/// Nothing in this footer reaches the provider: `system.neosync.sync` is false
/// for [_system], so `NeoSyncStatusIcon.willRender` short-circuits before it is
/// asked anything.
class _StubSync implements ISyncProvider {
  @override
  bool get isAuthenticated => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRaProvider extends RetroAchievementsProvider {
  @override
  bool get isConnected => false;
}

/// Long enough that it cannot fit the narrow card below, which is what puts it
/// on the marquee rather than in the line's static branch.
const String _longFileName =
    'Some Very Long ROM Filename Indeed (USA) (Rev 1) [!].chd';

SystemModel _system() => const SystemModel(
  folderName: 'psx',
  realName: 'Sony PlayStation',
  iconImage: '',
  color: '#FFFFFF',
);

GameModel _game() => GameModel(
  romname: _longFileName,
  realname: 'A Game',
  name: 'A Game',
  year: '1999',
  developer: '',
  // Long enough to overflow the status strip too, so both lines marquee and
  // both are covered rather than only the one the report came in about.
  publisher: 'Sony Computer Entertainment Europe Limited',
  genre: 'Role Playing Game',
  players: '1',
  rating: 18.0,
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

  Future<void> pumpFooter(WidgetTester tester) async {
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
                // Narrow on purpose: this is the card the footer is pinned to,
                // and both lines have to be wider than it.
                child: SizedBox(
                  width: 320,
                  height: 240,
                  child: Stack(children: [_footer()]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('both text lines are on the marquee at this width', (
    tester,
  ) async {
    // The premise of everything below. If a layout change ever makes these
    // lines fit, the two tests after this one would pass by vacancy.
    await pumpFooter(tester);

    expect(find.byType(ScrollingStatusLine), findsNWidgets(2));

    // Let the marquees' timers expire so none outlives the test.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('nothing inside a marquee is wrapped in a RepaintBoundary', (
    tester,
  ) async {
    await pumpFooter(tester);

    expect(
      find.descendant(
        of: find.byType(ScrollingStatusLine),
        matching: find.byType(RepaintBoundary),
      ),
      findsNothing,
      reason:
          'a retained layer is repositioned rather than repainted, and its '
          'paint bounds exclude the drop shadow hanging past the line box, so '
          'the text scrolls out from under its own shadow on any '
          'partial-repaint frame',
    );

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('both lines carry a shadow, and both are given room for it', (
    tester,
  ) async {
    await pumpFooter(tester);

    // The two facts are only worth anything together: room with no shadow is
    // pointless, and a shadow with no room is the bug.
    final TextStyle filenameStyle = tester
        .widget<Text>(find.text(_longFileName))
        .style!;
    expect(filenameStyle.shadows, isNotEmpty);

    for (final ScrollingStatusLine line
        in tester.widgetList<ScrollingStatusLine>(
          find.byType(ScrollingStatusLine),
        )) {
      expect(
        line.shadowRoom,
        greaterThan(0),
        reason:
            'SingleChildScrollView clips to its viewport in both axes once the '
            'content overflows, and these lines are fixed at 15.r/16.r with '
            'about a pixel of slack, so without this the shadow is cut off '
            'exactly when the line starts moving',
      );
    }

    await tester.pump(const Duration(seconds: 2));
  });
}

GameDetailsFooter _footer() => GameDetailsFooter(
  system: _system(),
  game: _game(),
  isMusicSystem: false,
  hasScreenScraper: false,
  isSecondaryScreenActive: false,
  cloudSyncEnabled: false,
  syncProvider: _StubSync(),
  onShowAchievements: () {},
  hasRetroAchievements: false,
  isLoadingAchievements: false,
);
