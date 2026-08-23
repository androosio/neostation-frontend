import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/footer_label_pill.dart';
import 'package:neostation/widgets/system_count_pill.dart';
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

  testWidgets('a recent-game card gets no count rather than an invented one', (
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
    expect(find.textContaining('Game'), findsNothing);
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
}
