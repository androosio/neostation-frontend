import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/screens/game_screen/game_details_card/tabs/game_details_game_info_tab.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/header_action_button.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The game info panel's header packs left: icon, gate chip, then the
/// developer / players / year strip in whatever room is left. Whether the chip
/// belongs there depends on `_canScroll`, which reads a scroll metric that does
/// not exist until the description has been laid out — so the panel's own first
/// build always answers "nothing to drive" and the chip is missing from it.
///
/// Nothing rebuilds the panel afterwards until the card does, and the next
/// thing that does is `_setTab`'s slide finishing (`_partnerTab = null`). The
/// chip therefore arrived on the frame the panel came to rest and shoved the
/// facts strip 132px to the right: a settle flash in the header, on every
/// arrival at the tab. Measured in this harness before the fix: devX 75 on the
/// first frames, 207 after the card's next rebuild.
///
/// The invariant these tests hold is that the header's layout does not depend
/// on when that metric becomes readable — the chip's room is reserved, so the
/// facts strip sits at the same x on the panel's first frame, after it has
/// measured itself, and across games that differ in what they have to drive.
final _system = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#ff006a',
);

const _paragraph =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
    'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. '
    'Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris. '
    'Duis aute irure dolor in reprehenderit in voluptate velit esse.';

/// Long enough to overrun the pane, so the description is genuinely scrollable
/// and the gate chip is one the panel does want to draw.
final _overflowing = List.filled(30, _paragraph).join(' ');

GameModel _game({Map<String, String?>? descriptions}) => GameModel(
  romname: 'game.sfc',
  realname: 'Game',
  name: 'Game',
  descriptions: descriptions,
  year: '1994',
  developer: 'Some Developer',
  publisher: 'Some Publisher',
  genre: 'Platform',
  players: '1-2',
  rating: 0.8,
  romPath: '/roms/snes/game.sfc',
);

/// The developer pill's left edge: the first thing in the facts strip, so it
/// moves the moment anything before it in the row changes width.
double _factsX(WidgetTester tester) =>
    tester.getTopLeft(find.text('Some Developer')).dx;

bool _chipShown(WidgetTester tester) => tester
    .widget<Visibility>(
      find.ancestor(
        of: find.byType(HeaderActionButton),
        matching: find.byType(Visibility),
      ),
    )
    .visible;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    SfxService().setEnabled(false);
  });

  /// Puts the panel on screen the way the card does: the surrounding tree is
  /// already laid out and `ScreenUtil` already initialised, then the panel is
  /// mounted and its *own* first frame is the one that gets sampled.
  ///
  /// Sampling that frame is the point. The fault is one build long, and a test
  /// that only starts looking after the first `pump` cannot see it.
  Future<void> mountPanel(
    WidgetTester tester,
    GameModel game,
    String description,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            // The panel asserts on these theme extensions, which the real app
            // always carries.
            theme: ThemeData(
              extensions: [ChromeSurface.standard(), CornerRadii.m()],
            ),
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 1000,
                child: _Host(
                  system: _system,
                  game: game,
                  description: description,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // ScreenUtilInit needs a frame of its own before anything measured with
    // `.r` is meaningful.
    await tester.pump(const Duration(milliseconds: 300));
    tester.state<_HostState>(find.byType(_Host)).mountPanel();
    await tester.pump();
  }

  testWidgets('the facts strip does not move once the panel measures itself', (
    tester,
  ) async {
    await mountPanel(
      tester,
      _game(descriptions: {'en': _overflowing}),
      _overflowing,
    );

    final onArrival = _factsX(tester);
    expect(
      _chipShown(tester),
      isFalse,
      reason: 'the first build cannot know the description overflows yet',
    );

    // The panel's post-frame check lands, finds a scrollable description and
    // shows the chip.
    await tester.pump();
    expect(_chipShown(tester), isTrue);
    expect(_factsX(tester), onArrival);

    // And the card's own next rebuild — on a device, the frame the tab slide
    // settles on — changes nothing either. This is the frame that used to
    // carry the flash.
    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    expect(_chipShown(tester), isTrue);
    expect(_factsX(tester), onArrival);
  });

  testWidgets('a description that fits leaves the header where it is', (
    tester,
  ) async {
    await mountPanel(tester, _game(descriptions: {'en': 'Short.'}), 'Short.');

    final onArrival = _factsX(tester);
    await tester.pump();
    expect(
      _chipShown(tester),
      isFalse,
      reason: 'nothing to scroll and one language: the gate refuses',
    );
    expect(_factsX(tester), onArrival);

    tester.state<_HostState>(find.byType(_Host)).rebuild();
    await tester.pump();
    expect(_factsX(tester), onArrival);
  });

  testWidgets('the header lines up across games with different gates', (
    tester,
  ) async {
    // One language and a description that fits: nothing to drive.
    await mountPanel(tester, _game(descriptions: {'en': 'Short.'}), 'Short.');
    await tester.pump();
    final quiet = _factsX(tester);

    // Two languages: the chip is wanted from the first build. Walking the games
    // list with this tab open must not shuffle the strip between the two.
    await mountPanel(
      tester,
      _game(descriptions: {'en': _paragraph, 'fr': _paragraph}),
      _paragraph,
    );
    final chipped = _factsX(tester);
    expect(_chipShown(tester), isTrue);
    await tester.pump();

    expect(chipped, quiet);
    expect(_factsX(tester), quiet);
  });
}

/// Stands in for the details card: it holds the panel and can rebuild it on
/// demand, which is what the card does when its tab slide finishes.
class _Host extends StatefulWidget {
  final SystemModel system;
  final GameModel game;
  final String description;

  const _Host({
    required this.system,
    required this.game,
    required this.description,
  });

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool _mounted = false;

  void mountPanel() => setState(() => _mounted = true);
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: SizedBox()),
      if (_mounted)
        GameDetailsGameInfoTab(
          system: widget.system,
          game: widget.game,
          fileProvider: FileProvider(),
          description: widget.description,
          isScrapingGame: false,
          onScrapeGame: () {},
        ),
    ],
  );
}
