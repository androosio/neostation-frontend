import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/scrolling_status_line.dart';

/// The details card footer's marquee. Its whole contract is invisible to a
/// screenshot taken at the wrong moment — it only moves when the row overflows,
/// and it ping-pongs rather than snapping back — so it is pinned down here.
void main() {
  Future<void> pumpStrip(
    WidgetTester tester, {
    required double slotWidth,
    required double contentWidth,
    String resetKey = 'a',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: slotWidth,
              height: 20,
              child: ScrollingStatusLine(
                resetKey: resetKey,
                children: [SizedBox(width: contentWidth, height: 20)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double offsetOf(WidgetTester tester) =>
      tester.widget<Scrollable>(find.byType(Scrollable)).controller!.offset;

  /// Runs the marquee's periodic timer for [ticks] frames, returning every
  /// offset it passed through. One long `pump` would elapse the clock but let
  /// the timer run only once, so the movement has to be driven frame by frame.
  Future<List<double>> track(WidgetTester tester, int ticks) async {
    final List<double> offsets = [];
    for (int i = 0; i < ticks; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      offsets.add(offsetOf(tester));
    }
    return offsets;
  }

  testWidgets('sits still when the row fits its slot', (tester) async {
    await pumpStrip(tester, slotWidth: 200, contentWidth: 120);

    final List<double> offsets = await track(tester, 100);
    expect(offsets.every((o) => o == 0), isTrue);
  });

  testWidgets('scrolls out to the end of an overflowing row, then back', (
    tester,
  ) async {
    // 400 of content in a 100 slot: 300 to travel.
    await pumpStrip(tester, slotWidth: 100, contentWidth: 400);

    // Held still at first, so the start of the row is readable before it moves.
    final List<double> hold = await track(tester, 10);
    expect(hold.every((o) => o == 0), isTrue);

    final List<double> offsets = await track(tester, 600);
    final double peak = offsets.reduce((a, b) => a > b ? a : b);

    // Reaches the far end exactly, and does not scroll on into empty space.
    expect(peak, 300);

    // Comes back rather than snapping to the start: after the peak it is seen
    // at intermediate offsets on the way down, not just at zero.
    final int peakAt = offsets.indexOf(peak);
    final List<double> after = offsets.sublist(peakAt);
    expect(after.any((o) => o > 0 && o < peak), isTrue);

    // ...and all the way back to the start, before setting off again.
    expect(after.any((o) => o == 0), isTrue);

    // Let the last scheduled hold expire so no timer outlives the test.
    await track(tester, 60);
  });

  testWidgets('restarts from the left when the selection changes', (
    tester,
  ) async {
    await pumpStrip(tester, slotWidth: 100, contentWidth: 400);
    await track(tester, 60);
    expect(offsetOf(tester), greaterThan(0));

    await pumpStrip(
      tester,
      slotWidth: 100,
      contentWidth: 400,
      resetKey: 'another-game',
    );
    await tester.pump();
    expect(offsetOf(tester), 0);

    // Clean up the timer the new strip scheduled.
    await track(tester, 60);
  });
}
