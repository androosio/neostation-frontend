import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the generic anchored context menu: what it renders, what it returns,
/// how the submenu level behaves, and the viewport flip that keeps the panel
/// on screen on the narrowest supported target (the Steam Deck's 1280x800).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SoLoud has no native library in the test host.
    SfxService().setEnabled(false);
    // Stub the gamepads plugin so GamepadNavigation.initialize() finds no
    // devices instead of relying on a real platform channel.
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

  const items = <ContextMenuItem>[
    ContextMenuItem(id: 'settings', label: 'Settings'),
    ContextMenuItem(
      id: 'add',
      label: 'Add to',
      children: [
        ContextMenuItem(id: 'add:favorites', label: 'Favorite'),
        ContextMenuItem(id: 'add:shooters', label: 'Shooters'),
      ],
    ),
  ];

  /// Sizes the test view so hit testing matches the logical viewport the menu
  /// clamps against.
  void useViewport(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

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

  testWidgets('renders one row per item', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showAnchoredContextMenu(context: ctx, items: items);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Add to'), findsOneWidget);
    // The submenu is closed, so its children are not in the tree yet.
    expect(find.text('Shooters'), findsNothing);
  });

  testWidgets('activating a leaf resolves with its id', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    String? result;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
    ).then((value) => result = value);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(result, 'settings');
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('a pre-opened submenu resolves with the child id', (
    tester,
  ) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    String? result;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
      openSubmenuAtIndex: 1,
      initialSubmenuIndex: 0,
    ).then((value) => result = value);
    await tester.pumpAndSettle();

    // Both levels are on screen; activating the child tears the stack down.
    expect(find.text('Favorite'), findsOneWidget);
    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();

    expect(result, 'add:favorites');
    expect(find.text('Add to'), findsNothing);
  });

  testWidgets('flips to the left of the anchor when the right edge overflows', (
    tester,
  ) async {
    // Steam Deck logical viewport — the tightest supported target.
    const size = Size(1280, 800);
    useViewport(tester, size);
    const anchor = Rect.fromLTWH(1180, 700, 90, 60);

    await tester.pumpWidget(
      host(const AnchoredContextMenu(items: items, anchorRect: anchor)),
    );
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.text('Settings'));
    // Flipped: the panel now sits left of the anchor and stays on screen.
    expect(panel.left, lessThan(anchor.left));
    expect(panel.right, lessThanOrEqualTo(size.width));
    // Clamped upward so the bottom edge is inside the viewport.
    expect(panel.bottom, lessThanOrEqualTo(size.height));
  });
}
