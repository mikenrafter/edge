// What the app is calculating right now (P4b): one process-wide stack of open
// steps that the status line reads. The derivation engine, the artifact warmer
// and compute-on-open reads report here on the MAIN isolate, around their own
// awaits; nothing crosses an isolate boundary. A step is closed in `finally`
// (AGENTS.md 4.3), so a failed or cancelled calculation never leaves one open.
import 'package:flutter/foundation.dart';

/// One open step: plain words and when it began.
class CalcStep {
  const CalcStep(this.label, this.startedAt);
  final String label;
  final DateTime startedAt;
}

/// Opaque handle from [CalcStatus.begin]; hand it back to [CalcStatus.end].
class CalcToken {
  CalcToken._(this._step);
  final CalcStep _step;
}

class CalcStatus implements ValueListenable<CalcStep?> {
  CalcStatus({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The one the app reports to and the status line reads.
  static final CalcStatus instance = CalcStatus();

  final DateTime Function() _clock;
  final List<CalcToken> _open = [];
  final List<VoidCallback> _listeners = [];

  /// The most recent step still open, or null when nothing is.
  @override
  CalcStep? get value => _open.isEmpty ? null : _open.last._step;

  CalcToken begin(String label) {
    final t = CalcToken._(CalcStep(label, _clock()));
    _open.add(t);
    _notify();
    return t;
  }

  /// Closes [token] wherever it sits; an unknown or already-closed one is a
  /// no-op. Only a change of the visible step notifies.
  void end(CalcToken token) {
    final i = _open.lastIndexOf(token);
    if (i < 0) return;
    final wasTop = i == _open.length - 1;
    _open.removeAt(i);
    if (wasTop) _notify();
  }

  /// Runs [body] as one step; closed whether it returns or throws.
  Future<T> run<T>(String label, Future<T> Function() body) async {
    final t = begin(label);
    try {
      return await body();
    } finally {
      end(t);
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final l in List.of(_listeners)) {
      if (_listeners.contains(l)) l();
    }
  }
}
