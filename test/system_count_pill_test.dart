import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/footer_label_pill.dart';
import 'package:neostation/widgets/system_count_pill.dart';
import 'package:neostation/widgets/systems_grid_footer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the count the carousel view floats over itself.
///
/// The carousel has no footer and no chip strip, and its cards no longer carry
/// their own count either: its pages are height-bound, so every row of chrome
/// under them costs the artwork width as well as height. The count is floated
/// instead, in the band the grid's footer occupies so it does not move when
/// the view mode changes.
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

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    builder: (context, _) => MaterialApp(
      localizationsDelegates:
          FlutterLocalization.instance.localizationsDelegates,
      supportedLocales: FlutterLocalization.instance.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  SystemInfo system({required String folderName, required int count}) =>
      SystemInfo(
        title: folderName,
        shortName: folderName,
        folderName: folderName,
        numOfRoms: count,
      );

  testWidgets('names the focused system\'s count', (tester) async {
    await tester.pumpWidget(
      host(SystemCountPill(system: system(folderName: 'nes', count: 12))),
    );
    await tester.pump();
    expect(find.text('12 Games'), findsOneWidget);
  });

  testWidgets('the noun follows the folder', (tester) async {
    await tester.pumpWidget(
      host(SystemCountPill(system: system(folderName: 'android', count: 7))),
    );
    await tester.pump();
    expect(find.text('7 Apps'), findsOneWidget);

    await tester.pumpWidget(
      host(SystemCountPill(system: system(folderName: 'music', count: 1))),
    );
    await tester.pump();
    expect(find.text('1 Track'), findsOneWidget);
  });

  // Was 'a recent-game card gets no count rather than an invented one', and
  // that is still half true: the card holds one game, so "1 Game" is a label
  // that says nothing. It carries the game's *name* there now instead — that
  // card wears its name only as wheel artwork, which not every game has and
  // which nothing falls back to when it is missing, and its own footer strip
  // is spent on the play time. The band was simply empty for it before.
  testWidgets('a recent-game card shows the game name, not a count', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SystemCountPill(
          system: SystemInfo(title: 'Sonic', shortName: 'Sonic', isGame: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Sonic'), findsOneWidget);
    expect(
      find.textContaining('Game'),
      findsNothing,
      reason: 'a count of one is not what that pill is for',
    );
  });

  testWidgets('a game card with no title still renders nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(SystemCountPill(system: SystemInfo(isGame: true))),
    );
    await tester.pump();
    expect(
      find.byType(FooterLabelPill),
      findsNothing,
      reason: 'an empty pill is worse than no pill',
    );
  });

  testWidgets('the label sits evenly inside the pill', (tester) async {
    // The pill's right inset is tighter than its left so it can sit close to
    // an optional count chip. This pill has no chip, so that inset only made
    // the label look off-centre.
    await tester.pumpWidget(
      host(SystemCountPill(system: system(folderName: 'nes', count: 12))),
    );
    await tester.pump();

    // The pill widget is an Align filling the row, so measure the painted
    // container rather than the slot it is aligned in.
    final pill = tester.getRect(
      find
          .descendant(
            of: find.byType(FooterLabelPill),
            matching: find.byType(Container),
          )
          .first,
    );
    final label = tester.getRect(find.text('12 Games'));

    expect(label.left - pill.left, closeTo(pill.right - label.right, 0.5));
  });

  testWidgets('floats in the band the grid footer occupies, bottom left', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Stack(
          children: [
            const SizedBox.expand(),
            SystemCountPill.floating(system(folderName: 'nes', count: 12)),
          ],
        ),
      ),
    );
    await tester.pump();

    final screen = tester.getRect(find.byType(Scaffold));
    final pill = tester.getRect(find.text('12 Games'));

    expect(pill.center.dx, lessThan(screen.center.dx));
    // Inside the footer band, i.e. within kCoreFooterHeight of the bottom.
    expect(
      screen.bottom - pill.center.dy,
      lessThan(ScreenUtil().radius(kCoreFooterHeight)),
    );
  });

  testWidgets('a long name ellipsizes instead of running off the view', (
    tester,
  ) async {
    // A `Positioned` with a `left` and no `right` hands its child infinite
    // width, so FooterLabelPill's `Flexible` and its ellipsis were both inert.
    // That never showed while the pill only ever said "1234 Games"; a game
    // name reaches the edge of the screen and simply ran off it.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      host(
        Stack(
          children: [
            const SizedBox.expand(),
            SystemCountPill.floating(
              SystemInfo(
                title:
                    'The Legend of Zelda: Ocarina of Time Master Quest '
                    'Collector Edition Special Anniversary Rerelease',
                isGame: true,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final screen = tester.getRect(find.byType(Scaffold));
    final pill = tester.getRect(find.byType(FooterLabelPill));
    expect(pill.width, lessThanOrEqualTo(screen.width * 0.5));
  });

  // The floating pill is placed to land exactly where the grid footer's pill
  // does, so the count does not move when the view mode changes. A label that
  // appeared in one view and not the other would re-open that same seam.
  group('the grid footer says the same thing', () {
    testWidgets('a system card shows its count', (tester) async {
      await tester.pumpWidget(
        host(SystemsGridFooter(system: system(folderName: 'nes', count: 12))),
      );
      await tester.pump();
      expect(find.text('12 Games'), findsOneWidget);
    });

    testWidgets('a recent-game card shows the game name', (tester) async {
      await tester.pumpWidget(
        host(
          SystemsGridFooter(
            system: SystemInfo(
              title: 'Sonic',
              shortName: 'Sonic',
              isGame: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Sonic'), findsOneWidget);
    });
  });
}
