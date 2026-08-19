import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/back_swipe_zone.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the app-wide touch route to "back": a swipe-right from the left edge
/// dispatched to whatever the active navigation layer means by B.
///
/// The zone is mounted once over the whole app, so the contract that matters is
/// the dispatch seam — it must reach the *active* layer, stay silent when that
/// layer has no back action, and never fire on a stray horizontal twitch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
  });

  /// Mounts the zone over a full-screen placeholder, the way the app root does.
  Future<void> pumpZone(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, _) => MaterialApp(
          home: Stack(
            children: const [
              SizedBox.expand(child: ColoredBox(color: Colors.black)),
              BackSwipeZone(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Registers a navigator as the active layer and returns a counter its back
  /// action increments. Deactivated on teardown so layers never leak between
  /// tests through the shared static.
  List<int> activateLayerWithBack(WidgetTester tester, {VoidCallback? onBack}) {
    final fired = <int>[];
    final nav = GamepadNavigation(
      onBack: onBack ?? () => fired.add(1),
      isTextFieldFocused: () => false,
    );
    nav.activate();
    addTearDown(nav.dispose);
    return fired;
  }

  /// A deliberate swipe right, starting inside the edge strip.
  Future<void> swipeRight(WidgetTester tester, {double distance = 120}) async {
    await tester.timedDrag(
      find.byType(BackSwipeZone),
      Offset(distance, 0),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a swipe right fires the active layer\'s back action', (
    tester,
  ) async {
    await pumpZone(tester);
    final fired = activateLayerWithBack(tester);

    await swipeRight(tester);

    expect(fired, hasLength(1));
  });

  testWidgets('the newest active layer is the one that goes back', (
    tester,
  ) async {
    await pumpZone(tester);
    final under = activateLayerWithBack(tester);
    final over = activateLayerWithBack(tester);

    await swipeRight(tester);

    expect(over, hasLength(1), reason: 'the top layer owns back');
    expect(under, isEmpty, reason: 'a buried layer must not also fire');
  });

  testWidgets('a layer with no back action is a silent no-op', (tester) async {
    await pumpZone(tester);
    final nav = GamepadNavigation(isTextFieldFocused: () => false);
    nav.activate();
    addTearDown(nav.dispose);

    // The gesture must not throw or reach anything; triggerBack reports it
    // handled nothing.
    await swipeRight(tester);

    expect(GamepadNavigation.triggerBack(), isFalse);
  });

  testWidgets('a short twitch does not count as a back swipe', (tester) async {
    await pumpZone(tester);
    final fired = activateLayerWithBack(tester);

    // Under the distance threshold and slow enough to miss the velocity one.
    await tester.timedDrag(
      find.byType(BackSwipeZone),
      const Offset(12, 0),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();

    expect(fired, isEmpty);
  });

  testWidgets('a swipe left is not a back swipe', (tester) async {
    await pumpZone(tester);
    final fired = activateLayerWithBack(tester);

    await swipeRight(tester, distance: -120);

    expect(fired, isEmpty);
  });
}
