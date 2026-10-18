import 'dart:async';

/// At most one publish per [minGap] while a pass commits days, with a trailing
/// fire so the LAST committed day always publishes. Pure: the clock and the
/// timer are injected.
class RevisionCoalescer {
  RevisionCoalescer({
    required void Function() fire,
    required int Function() nowMs,
    this.minGap = const Duration(milliseconds: 1500),
    Timer Function(Duration, void Function()) timer = Timer.new,
  })  : _fire = fire,
        _now = nowMs,
        _timer = timer;

  final void Function() _fire;
  final int Function() _now;
  final Duration minGap;
  final Timer Function(Duration, void Function()) _timer;

  int? _lastFireAt;
  Timer? _pending;
  bool _disposed = false;

  /// A trailing fire is scheduled.
  bool get pending => _pending != null;

  /// A day just committed.
  void request() {
    if (_disposed || _pending != null) return;
    final last = _lastFireAt;
    final elapsed = last == null ? null : _now() - last;
    if (elapsed == null || elapsed >= minGap.inMilliseconds) {
      _fireNow();
      return;
    }
    _pending = _timer(Duration(milliseconds: minGap.inMilliseconds - elapsed), () {
      _pending = null;
      if (!_disposed) _fireNow();
    });
  }

  void _fireNow() {
    _lastFireAt = _now();
    _fire();
  }

  /// Cancels the trailing fire; later requests do nothing.
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _pending = null;
  }
}
