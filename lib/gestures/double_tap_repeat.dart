// double_tap_repeat.dart — the slower multi-tap method that needs no ECG:
// repeated firmware double taps, on any band.
//
// The first live double tap opens a window. Each further LIVE double tap inside
// it adds one (the count starts at 2, the same slots as the ECG counter), buzzes
// once, and restarts the window. When the window runs out the count is final
// and the caller runs the actions mapped to it; reaching the most taps anything
// is mapped to finishes at once. Only live taps count: a tap that reached the
// phone late (drained from the band's flash) never opens or extends a window.
//
// Pure timing: no BLE, no storage, no wall-clock reads beyond `clock.now()` for
// the trace. The buzz is injected (AppState routes it through AlertDispatcher).
// Every exit goes through [_finish], which resets every flag in `finally`.

import 'dart:async';

import 'package:clock/clock.dart';

import 'strap_event.dart';

class DoubleTapRepeatSession {
  DoubleTapRepeatSession({
    required this.maxTaps,
    required this.window,
    this.buzz,
    this.step,
    this.onStarted,
    this.onFinished,
  });

  /// The most taps worth waiting for (2..5). Reaching it finishes at once.
  final int Function() maxTaps;

  /// The pause allowed after each double tap. Read again on every restart, so
  /// the setting can change between gestures.
  final Duration Function() window;

  /// Buzz the band once for [eventId]. True when written; failures are logged
  /// and never stop the count.
  final Future<bool> Function(String eventId)? buzz;

  /// A line for the Device lab's trace.
  final void Function(String line)? step;

  /// A gesture began: the opening tap and a one-line description of the window.
  final void Function(StrapEvent first, String settings)? onStarted;

  /// The gesture ended with [count] taps.
  final void Function(int count)? onFinished;

  /// A second delivery of the same tap (a re-send) is not another tap. With no
  /// usable strap clock every tap has the same identity, so those are told
  /// apart by receipt time instead.
  static const Duration _receiptDebounce = Duration(milliseconds: 400);

  StrapEvent? _first;
  Completer<int>? _done;
  Timer? _timer;
  int _count = 0;
  DateTime? _lastTapAt;
  DateTime? _lastReceipt;
  final Set<String> _seen = {};
  int _buzzes = 0;

  bool get open => _done != null;
  int get count => _count;

  /// Open a window for [first] (count 2). Completes with the final count.
  /// Throws StateError for a tap that is not live or when one is already open;
  /// the dispatcher checks both first.
  Future<int> begin(StrapEvent first) {
    if (open) throw StateError('a double-tap window is already open');
    if (!first.isLive) throw StateError('only a live double tap opens a window');
    final done = _done = Completer<int>();
    _first = first;
    _count = 2;
    _seen
      ..clear()
      ..add(first.identity);
    _lastReceipt = first.receivedAt;
    _lastTapAt = clock.now();
    _buzzes = 0;
    final w = window();
    try {
      onStarted?.call(first, 'window ${w.inMilliseconds} ms');
    } catch (_) {}
    step?.call(
      'Double tap 1 received. Waiting ${w.inMilliseconds} ms for another.',
    );
    _arm(w);
    return done.future;
  }

  /// Offer a further double tap. True when it was counted.
  bool add(StrapEvent e) {
    if (!open) return false;
    if (!e.isLive) {
      step?.call('Ignored a late double tap (it reached the phone too long '
          'after it happened).');
      return false;
    }
    final seenBefore = e.plausible
        ? _seen.contains(e.identity)
        : e.receivedAt.difference(_lastReceipt ?? e.receivedAt).abs() <
            _receiptDebounce;
    if (seenBefore) {
      step?.call('Ignored the same double tap seen again.');
      return false;
    }
    _seen.add(e.identity);
    _lastReceipt = e.receivedAt;
    final now = clock.now();
    final since = now.difference(_lastTapAt ?? now).inMilliseconds;
    _lastTapAt = now;
    _count++;
    step?.call(
      'Double tap ${_count - 1} received, $since ms after the last one. '
      'Count is $_count.',
    );
    _requestBuzz();
    if (_count >= maxTaps()) {
      step?.call('Reached $_count, the most taps anything is set to.');
      _finish();
    } else {
      _arm(window());
    }
    return true;
  }

  /// Finish a waiting gesture with the count so far (the app is going away).
  void dispose() {
    if (open) {
      step?.call('Stopped early.');
      _finish();
    }
  }

  void _arm(Duration w) {
    _timer?.cancel();
    _timer = Timer(w, () {
      final since = clock.now().difference(_lastTapAt ?? clock.now());
      step?.call(
        'Window ran out ${since.inMilliseconds} ms after the last tap. '
        'Final count $_count.',
      );
      _finish();
    });
  }

  void _requestBuzz() {
    final send = buzz, first = _first;
    if (send == null || first == null) return;
    final base = first.plausible
        ? first.identity
        : '${first.identity}:${first.receivedAt.microsecondsSinceEpoch}';
    final id = '$base:rep:${_buzzes++}';
    final sent = clock.now();
    step?.call('Buzz requested.');
    unawaited(() async {
      var ok = false;
      try {
        ok = await send(id);
      } catch (_) {}
      step?.call(
        ok
            ? 'Buzz written, ${clock.now().difference(sent).inMilliseconds} '
                'ms after the request.'
            : 'Buzz could not be written.',
      );
    }());
  }

  void _finish() {
    final done = _done;
    if (done == null) return;
    final count = _count;
    try {
      _timer?.cancel();
    } finally {
      _timer = null;
      _done = null;
      _first = null;
      _count = 0;
      _seen.clear();
      _lastTapAt = null;
      _lastReceipt = null;
    }
    try {
      onFinished?.call(count);
    } catch (_) {}
    if (!done.isCompleted) done.complete(count);
  }
}
