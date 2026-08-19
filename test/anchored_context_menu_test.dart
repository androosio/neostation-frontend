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

  /// Waits out [GamepadNavigation]'s post-activation grace window, which drops
  /// every key event for 150 real milliseconds after a layer is activated. Fake
  /// time does not move it, so the wait has to be a real one.
  Future<void> settleNavGrace(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
  }

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

  testWidgets('D-pad left leaves the root menu open', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    var resolved = false;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
    ).then((_) => resolved = true);
    await tester.pumpAndSettle();
    await settleNavGrace(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    // Left is inert at the root: only B (or a tap outside) dismisses it.
    expect(find.text('Settings'), findsOneWidget);
    expect(resolved, isFalse);
  });

  testWidgets('D-pad left closes a submenu back to its parent', (tester) async {
    useViewport(tester, const Size(1920, 1080));
    final ctx = await pumpHost(tester);
    var resolved = false;
    // ignore: unawaited_futures
    showAnchoredContextMenu(
      context: ctx,
      items: items,
      openSubmenuAtIndex: 1,
    ).then((_) => resolved = true);
    await tester.pumpAndSettle();

    expect(find.text('Favorite'), findsOneWidget);
    await settleNavGrace(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    // One level walked back, the parent menu is still up.
    expect(find.text('Favorite'), findsNothing);
    expect(find.text('Add to'), findsOneWidget);
    expect(resolved, isFalse);
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

  testWidgets('overAnchor starts the panel at the anchor\'s left edge', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // A full-width games-list row: hanging the panel off its right edge would
    // shove it against the far side of the screen.
    const anchor = Rect.fromLTWH(40, 100, 520, 40);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.text('Settings'));
    expect(row.left, greaterThanOrEqualTo(anchor.left));
    expect(row.left, lessThan(anchor.center.dx));
    // Below the anchor, not over it: the row it was opened on stays readable.
    expect(row.top, greaterThanOrEqualTo(anchor.bottom));
  });

  testWidgets('overAnchor flips above the anchor rather than off the bottom', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // Last visible row of the list: there is no room underneath it.
    const anchor = Rect.fromLTWH(40, 740, 520, 40);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.text('Settings'));
    expect(row.bottom, lessThanOrEqualTo(anchor.top));
  });

  testWidgets('a submenu opens to the right of the menu that spawned it', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    const anchor = Rect.fromLTWH(40, 100, 520, 40);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          alignment: ContextMenuAlignment.overAnchor,
          openSubmenuAtIndex: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Right is the button that opens a submenu, so right is where it appears.
    expect(
      tester.getRect(find.text('Favorite')).left,
      greaterThan(tester.getRect(find.text('Add to')).left),
    );
  });

  testWidgets('an anchor at the right edge still leaves room for a submenu', (
    tester,
  ) async {
    const size = Size(1280, 800);
    useViewport(tester, size);
    // Grid card hard against the right edge: the panel has to give up its
    // preferred position entirely so the submenu is not forced back over it.
    const anchor = Rect.fromLTWH(1150, 100, 120, 120);

    await tester.pumpWidget(
      host(
        const AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          openSubmenuAtIndex: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final parent = tester.getRect(find.text('Add to'));
    final submenu = tester.getRect(find.text('Favorite'));
    expect(submenu.left, greaterThan(parent.left));
    expect(submenu.right, lessThanOrEqualTo(size.width));
  });
}
