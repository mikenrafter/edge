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
// GROUPING IS BY THE BAND'S TIME (review finding I). Receipt time only says when
// the phone heard about a tap: a link that was down delivers several taps in one
// burst, and grouping on the receipt clock would call two taps 3 s apart a triple
// because they arrived together. While the strap clock is believable
// (StrapEvent.plausible) an event joins the open group only if its effective
// (band) time is within the window of a member's (inclusive): adjacent taps
// chain, so a long run of quick taps is one group. A LATER tap further than that
// ends the group and starts the next ([RepeatOffer.newGroup]); an EARLIER one is
// a member if it falls within the window of one (bounded reordering) and is
// otherwise unrelated and ignored. Receipt time (`clock.now()`, the window
// timer) is the fallback only when the opener or the tap has an implausible
// clock. Known limit: the window TIMER still runs on the phone clock, so a tap
// that is within the window by band time but delivered after the timer fired
// opens the next group.
//
// CUES (8AK). The same additive cues as the ECG route: the start cue once when
// the first double tap opens the window, one follow-up per further double tap,
// the confirm when the gesture ends counted (never when it is stopped early).
// With [bandIdle] the pause window is armed only after the cue of the tap that
// opens or extends it was delivered AND the band finished playing it: tap ->
// confirm -> tap -> confirm. While the cue plays no window is running, so the
// wearer is not timed out by the cue they are feeling; [cueTimeout] bounds the
// wait. Without [bandIdle] the window is armed at the tap, as before.
//
// Pure timing: no BLE, no storage. The cues are injected (AppState routes them
// through AlertDispatcher). Every exit goes through [_finish], which resets
// every flag in `finally`.

import 'dart:async';

import 'package:clock/clock.dart';

import 'strap_event.dart';

/// What [DoubleTapRepeatSession.offer] did with a tap.
enum RepeatOffer {
  /// Joined the open group.
  counted,

  /// Not part of this gesture (a re-send, a late tap, an older stray tap).
  ignored,

  /// Happened too long after the group's last tap, by the band clock: the open
  /// group was FINISHED (its count is final) and the caller should treat this
  /// tap as the first of a new one.
  newGroup,
}

class DoubleTapRepeatSession {
  DoubleTapRepeatSession({
    required this.maxTaps,
    required this.window,
    this.buzz,
    this.startBuzz,
    this.confirmBuzz,
    this.bandIdle,
    this.cueTimeout = const Duration(seconds: 15),
    this.step,
    this.onStarted,
    this.onFinished,
  });

  /// The most taps worth waiting for (2..5). Reaching it finishes at once.
  final int Function() maxTaps;

  /// The pause allowed after each double tap. Read again on every restart, so
  /// the setting can change between gestures.
  final Duration Function() window;

  /// The follow-up cue for [eventId], once per further double tap. True when
  /// written; failures are logged and never stop the count.
  final Future<bool> Function(String eventId)? buzz;

  /// The start cue, once, in the turn the first double tap opens the window
  /// (id `<gesture id>:rep:start`).
  final Future<bool> Function(String eventId)? startBuzz;

  /// The confirm cue, once, when the gesture ends counted (id
  /// `<gesture id>:rep:confirm`), requested behind the cue before it. Not
  /// played for a gesture that is stopped early.
  final Future<bool> Function(String eventId)? confirmBuzz;

  /// Completes once the band finished playing everything queued so far (every
  /// cue delivered and its plan ended). Null: the window is armed at the tap.
  final Future<void> Function()? bandIdle;

  /// The longest a cue may hold the window back (its write and its playback),
  /// so a cue that never ends or never answers cannot freeze the gesture.
  final Duration cueTimeout;

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
  // Effective (band) times of the members, while every member's clock is
  // believable; null once any member's is not (receipt time then decides).
  List<DateTime>? _bandTimes;
  int _buzzes = 0;
  // The newest cue's write, so the confirm is requested behind it.
  Future<void> _lastCue = Future<void>.value();
  // Window arming that waits for a cue: only the newest wait may arm, and the
  // window is not running while one waits.
  int _armEpoch = 0;
  bool _waitingForCue = false;
  // How long after the last tap the window was actually armed (the time its
  // cue took), added to the window when grouping taps by the band's clock.
  Duration _cueDelay = Duration.zero;

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
    _bandTimes = first.plausible ? [first.effectiveTime] : null;
    _lastTapAt = clock.now();
    _buzzes = 0;
    _cueDelay = Duration.zero;
    final w = window();
    try {
      onStarted?.call(first, 'window ${w.inMilliseconds} ms');
    } catch (_) {}
    step?.call(
      'Double tap 1 received. Waiting ${w.inMilliseconds} ms for another.',
    );
    _armAfter(_requestCue(startBuzz, 'start', 'Start buzz'));
    return done.future;
  }

  /// Offer a further double tap. True when it was counted.
  bool add(StrapEvent e) => offer(e) == RepeatOffer.counted;

  /// Offer a further double tap and say what happened to it. A
  /// [RepeatOffer.newGroup] has already finished the open group.
  RepeatOffer offer(StrapEvent e) {
    if (!open) return RepeatOffer.ignored;
    if (!e.isLive) {
      step?.call('Ignored a late double tap (it reached the phone too long '
          'after it happened).');
      return RepeatOffer.ignored;
    }
    final seenBefore = e.plausible
        ? _seen.contains(e.identity)
        : e.receivedAt.difference(_lastReceipt ?? e.receivedAt).abs() <
            _receiptDebounce;
    if (seenBefore) {
      step?.call('Ignored the same double tap seen again.');
      return RepeatOffer.ignored;
    }
    final times = _bandTimes;
    if (times != null && e.plausible) {
      // The window runs from the end of the last cue, so a tap can be that much
      // later by the band's clock and still be inside it.
      final w = window() + (_waitingForCue ? cueTimeout : _cueDelay);
      final at = e.effectiveTime;
      var nearest = times.first;
      for (final t in times) {
        if ((at.difference(t)).abs() < (at.difference(nearest)).abs()) {
          nearest = t;
        }
      }
      final delta = at.difference(nearest);
      if (delta.abs() > w) {
        final latest = times.reduce((a, b) => a.isAfter(b) ? a : b);
        if (at.isAfter(latest)) {
          step?.call('This double tap came ${delta.inMilliseconds} ms after '
              'the last one by the band clock, more than the '
              '${w.inMilliseconds} ms window: the group ends at $_count and '
              'this one starts the next.');
          _finish(confirm: true);
          return RepeatOffer.newGroup;
        }
        step?.call('Ignored a double tap that happened ${-delta.inMilliseconds} '
            'ms before the nearest one by the band clock (older than the '
            '${w.inMilliseconds} ms window, so not part of this gesture).');
        return RepeatOffer.ignored;
      }
      step?.call('Band clock: this tap is ${delta.inMilliseconds.abs()} ms '
          '${delta.isNegative ? 'before the nearest tap' : 'after the nearest earlier tap'}'
          ' by the band clock.');
      times.add(at);
    } else {
      // An implausible strap clock on this tap or an earlier one: receipt time
      // is all there is.
      _bandTimes = null;
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
    final sent = _requestCue(buzz, '${_buzzes++}', 'Buzz');
    if (_count >= maxTaps()) {
      step?.call('Reached $_count, the most taps anything is set to.');
      _finish(confirm: true);
    } else {
      _armAfter(sent);
    }
    return RepeatOffer.counted;
  }

  /// Finish a waiting gesture with the count so far (the app is going away).
  void dispose() {
    if (open) {
      step?.call('Stopped early.');
      _finish();
    }
  }

  /// Arm the pause window for the tap just counted. With [bandIdle] it waits
  /// for [sent] (the tap's cue, delivered) and the band to finish playing,
  /// bounded by [cueTimeout]; the window is not running meanwhile.
  void _armAfter(Future<void> sent) {
    final idle = bandIdle;
    _timer?.cancel();
    _timer = null;
    if (idle == null) {
      _arm(window());
      return;
    }
    final epoch = ++_armEpoch;
    _waitingForCue = true;
    unawaited(() async {
      try {
        await (() async {
          await sent;
          await idle();
        })()
            .timeout(cueTimeout);
      } catch (_) {
        step?.call('The cue did not finish in time; the window opens anyway.');
      }
      if (epoch != _armEpoch || !open) return;
      _waitingForCue = false;
      _cueDelay = clock.now().difference(_lastTapAt ?? clock.now());
      step?.call('Cue played. Waiting ${window().inMilliseconds} ms for '
          'another.');
      _arm(window());
    }());
  }

  void _arm(Duration w) {
    _timer?.cancel();
    _timer = Timer(w, () {
      final since = clock.now().difference(_lastTapAt ?? clock.now());
      step?.call(
        'Window ran out ${since.inMilliseconds} ms after the last tap. '
        'Final count $_count.',
      );
      _finish(confirm: true);
    });
  }

  /// Ask for one cue with this gesture's id `<base>:rep:<suffix>`, now. The
  /// future completes when it was written (or could not be): it never throws.
  Future<void> _requestCue(
    Future<bool> Function(String eventId)? send,
    String suffix,
    String what,
  ) {
    final first = _first;
    if (send == null || first == null) return Future<void>.value();
    final sent = clock.now();
    step?.call('$what requested.');
    final f = () async {
      var ok = false;
      try {
        ok = await send(_cueId(first, suffix));
      } catch (_) {}
      step?.call(
        ok
            ? '$what written, ${clock.now().difference(sent).inMilliseconds} '
                'ms after the request.'
            : '$what could not be written.',
      );
    }();
    return _lastCue = f;
  }

  String _cueId(StrapEvent first, String suffix) {
    final base = first.plausible
        ? first.identity
        : '${first.identity}:${first.receivedAt.microsecondsSinceEpoch}';
    return '$base:rep:$suffix';
  }

  void _finish({bool confirm = false}) {
    final done = _done;
    if (done == null) return;
    final count = _count;
    final first = _first;
    final behind = _lastCue;
    try {
      _timer?.cancel();
    } finally {
      _timer = null;
      _armEpoch++;
      _waitingForCue = false;
      _lastCue = Future<void>.value();
      _done = null;
      _first = null;
      _count = 0;
      _seen.clear();
      _bandTimes = null;
      _lastTapAt = null;
      _lastReceipt = null;
    }
    try {
      onFinished?.call(count);
    } catch (_) {}
    if (confirm && first != null) _requestConfirm(first, behind);
    if (!done.isCompleted) done.complete(count);
  }

  /// The confirm, requested once the cue before it was written (bounded), so it
  /// queues behind that cue. The gesture is already over: this uses only what
  /// [_finish] captured.
  void _requestConfirm(StrapEvent first, Future<void> behind) {
    final send = confirmBuzz;
    if (send == null) return;
    unawaited(() async {
      try {
        await behind.timeout(cueTimeout);
      } catch (_) {}
      step?.call('Confirm buzz requested.');
      var ok = false;
      try {
        ok = await send(_cueId(first, 'confirm'));
      } catch (_) {}
      step?.call(ok
          ? 'Confirm buzz written.'
          : 'Confirm buzz could not be written.');
    }());
  }
}
