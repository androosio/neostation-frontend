import 'dart:async';
import 'package:flutter/material.dart';

/// A single-line horizontal marquee for the details card's footer — the
/// metadata strip, and the ROM filename when it is wider than its line.
///
/// Built on a [Timer.periodic] driving a [ScrollController] directly, so the
/// parent's frequent `setState` calls (the footer rebuilds on every sync tick
/// and every achievements poll) cannot disturb the movement.
///
/// The details card used to scroll its description on the same engine. That
/// one is gone: a description is read, not glanced at, so it holds still and
/// takes a drag or the D-pad instead. A one-line strip that is wider than its
/// slot has nowhere else to go, so this one stays — and it only moves when the
/// row genuinely overflows; anything that fits sits still.
class ScrollingStatusLine extends StatefulWidget {
  /// The strip's contents, already separated. Laid out in a `Row` that keeps
  /// its intrinsic width, which is what the overflow test compares against.
  final List<Widget> children;

  /// Identity of what is being described, so a change of selection restarts
  /// the marquee from the left rather than leaving the new game's strip parked
  /// mid-scroll at the old one's offset.
  final String resetKey;

  const ScrollingStatusLine({
    super.key,
    required this.children,
    required this.resetKey,
  });

  @override
  State<ScrollingStatusLine> createState() => _ScrollingStatusLineState();
}

class _ScrollingStatusLineState extends State<ScrollingStatusLine> {
  final ScrollController _scrollController = ScrollController();
  Timer? _timer;

  /// Which way the strip is currently travelling. It ping-pongs — out to the
  /// end, hold, back to the start, hold — rather than snapping back to zero
  /// once it reaches the end. A jump reads as a glitch on a line the eye is
  /// already following, and reversing keeps every part of the strip on screen
  /// twice as often.
  bool _forward = true;

  /// Faster than the description marquee's 20 px/s. That one paces a
  /// paragraph somebody is reading along with; this is a short strip being
  /// skimmed for one fact, so the wait for the far end to come round is the
  /// thing to minimise.
  static const double _pixelsPerSecond = 34.0;
  static const Duration _tick = Duration(milliseconds: 50);
  static final double _pixelsPerTick =
      _pixelsPerSecond * _tick.inMilliseconds / 1000.0;

  /// Held at each end of the travel so both ends of the strip can actually be
  /// read before it turns around. The first is shorter: a strip that overflows
  /// should start moving while the user is still looking at the card.
  static const int _startDelayMs = 900;
  static const int _endDelayMs = 1400;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The card can drop this line before its first frame (a fast selection
      // change); a timer armed after dispose would outlive the widget.
      if (!mounted) return;
      _scheduleStart(_startDelayMs);
    });
  }

  @override
  void didUpdateWidget(ScrollingStatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) {
      _cancelTimer();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _forward = true;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        _scheduleStart(_startDelayMs);
      });
    }
  }

  void _scheduleStart(int delayMs) {
    _cancelTimer();
    _timer = Timer(Duration(milliseconds: delayMs), _startTicking);
  }

  void _startTicking() {
    _cancelTimer();
    _timer = Timer.periodic(_tick, _onTick);
  }

  void _onTick(Timer timer) {
    if (!mounted) {
      timer.cancel();
      return;
    }
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) {
      // The strip fits: nothing to scroll, and no reason to keep a timer alive
      // for every selected game that happens to be short.
      timer.cancel();
      return;
    }

    final current = _scrollController.offset;
    final bool atEnd = _forward ? current >= maxScroll - 0.5 : current <= 0.5;

    if (atEnd) {
      // Hold at the end reached, then turn around and travel back.
      timer.cancel();
      _timer = Timer(const Duration(milliseconds: _endDelayMs), () {
        if (!mounted) return;
        _forward = !_forward;
        _startTicking();
      });
    } else {
      _scrollController.jumpTo(
        (current + (_forward ? _pixelsPerTick : -_pixelsPerTick)).clamp(
          0.0,
          maxScroll,
        ),
      );
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _cancelTimer();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      // Touch dragging is off: the strip is a readout, and a stray swipe on it
      // would fight the marquee's own offset.
      physics: const NeverScrollableScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: widget.children,
      ),
    );
  }
}
