import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/context_menu/game_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the view-level actions the game context menu absorbed when the
/// vertical action rail was removed: view mode and random. With no rail and no
/// button legend in the games views, this menu is the only route to them for a
/// user without a gamepad, so each row has to be present when the host binds it
/// and absent when it does not. Scrape is deliberately not one of them — it
/// lives in game settings and in the scrape tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  final targets = <GameContextMenuTarget>[
    GameContextMenuTarget(
      id: 'favorites',
      label: 'Favorite',
      icon: Symbols.favorite_rounded,
      isMember: false,
      add: () async {},
      remove: () async {},
    ),
  ];

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(1920, 1080),
    builder: (context, _) => MaterialApp(
      localizationsDelegates:
          FlutterLocalization.instance.localizationsDelegates,
      supportedLocales: FlutterLocalization.instance.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  String label(BuildContext context, String key) => key.getString(context);

  testWidgets('renders a row for every view-level action the host binds', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: targets,
      onSettings: () {},
      onViewMode: () {},
      onRandom: () {},
    );
    await tester.pumpAndSettle();

    expect(find.text(label(ctx, AppLocale.viewMode)), findsOneWidget);
    expect(find.text(label(ctx, AppLocale.randomGame)), findsOneWidget);
    // Scrape is not offered here at all.
    expect(find.text(label(ctx, AppLocale.hintScrape)), findsNothing);
  });

  testWidgets('opens on Settings, with no submenu pre-opened', (tester) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: targets,
      onSettings: () {},
      onViewMode: () {},
      onRandom: () {},
    );
    await tester.pumpAndSettle();

    // The focused row is drawn bold; Settings is the one the cursor starts on.
    final settings = tester.widget<Text>(
      find.text(label(ctx, AppLocale.gameSettings)),
    );
    expect(settings.style?.fontWeight, FontWeight.w700);
    // Nothing from `Add to…` is on screen: the submenu is closed.
    expect(find.text('Favorite'), findsNothing);
  });

  testWidgets('omits the rows the host leaves unbound', (tester) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: targets,
      onSettings: () {},
      onRandom: () {},
    );
    await tester.pumpAndSettle();

    expect(find.text(label(ctx, AppLocale.viewMode)), findsNothing);
    expect(find.text(label(ctx, AppLocale.randomGame)), findsOneWidget);
  });

  testWidgets('tapping a view-level row fires it and closes the menu', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    var viewMode = 0;
    var random = 0;
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: targets,
      onSettings: () {},
      onViewMode: () => viewMode++,
      onRandom: () => random++,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(label(ctx, AppLocale.viewMode)));
    await tester.pumpAndSettle();

    expect(viewMode, 1);
    expect(random, 0);
    expect(find.text(label(ctx, AppLocale.viewMode)), findsNothing);
  });

  testWidgets('the membership rows still work alongside them', (tester) async {
    final ctx = await pumpHost(tester);
    var added = 0;
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: <GameContextMenuTarget>[
        GameContextMenuTarget(
          id: 'favorites',
          label: 'Favorite',
          icon: Symbols.favorite_rounded,
          isMember: false,
          add: () async => added++,
          remove: () async {},
        ),
      ],
      onSettings: () {},
      onViewMode: () {},
      onRandom: () {},
    );
    await tester.pumpAndSettle();

    // Favourites now costs one more press: open `Add to…`, then activate it.
    await tester.tap(find.text(label(ctx, AppLocale.addTo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();

    expect(added, 1);
  });
}
