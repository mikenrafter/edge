// gesture_failures.dart — the persisted record of gestures that failed to
// activate. One entry per failed gesture (an ECG count that could not
// start or lost the stream, or a double-tap action that failed), newest first,
// bounded. Home shows the newest undismissed one as a card; Settings lists them
// all. The record carries the Device lab's log as it was at the time, so a
// report can be sent after the lab has moved on.
//
// Storage is one JSON string handed in by the caller (production: Prefs). A
// string that cannot be read is an empty store, a bad entry is dropped on its
// own, and a write that fails leaves the in-memory state standing. Nothing here
// throws to the caller.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'strap_event.dart';

enum GestureFailureKind { ecg, doubleTap }

/// The failure id of a tap: its identity, and for a tap with no usable strap
/// clock (every such tap shares one identity) its receipt time too, so two
/// failures are never taken for one.
String gestureFailureId(StrapEvent e) => e.plausible
    ? e.identity
    : '${e.identity}@${e.receivedAt.millisecondsSinceEpoch}';

@immutable
class GestureFailure {
  const GestureFailure({
    required this.gestureId,
    required this.at,
    required this.kind,
    required this.reason,
    required this.log,
    this.dismissed = false,
  });

  /// The tap's identity: one failure per gesture.
  final String gestureId;

  /// When it failed (the store's clock).
  final DateTime at;
  final GestureFailureKind kind;

  /// 'start_failed', 'link_lost', ... for an ECG gesture; for a double tap the
  /// action that failed.
  final String reason;

  /// The relevant session log, plain text.
  final String log;
  final bool dismissed;

  GestureFailure asDismissed() => GestureFailure(
        gestureId: gestureId,
        at: at,
        kind: kind,
        reason: reason,
        log: log,
        dismissed: true,
      );

  Object toJson() => {
        'id': gestureId,
        'at': at.toUtc().millisecondsSinceEpoch,
        'kind': kind.name,
        'reason': reason,
        'log': log,
        'dismissed': dismissed,
      };

  /// Throws on anything that is not a failure written by [toJson].
  factory GestureFailure.fromJson(Object? j) {
    if (j is! Map) throw const FormatException('not a gesture failure');
    final id = j['id'], at = j['at'], kind = j['kind'];
    final reason = j['reason'], log = j['log'], dismissed = j['dismissed'];
    if (id is! String || id.isEmpty || at is! int || kind is! String) {
      throw const FormatException('gesture failure fields');
    }
    return GestureFailure(
      gestureId: id,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      kind: GestureFailureKind.values.byName(kind),
      reason: reason is String ? reason : '',
      log: log is String ? log : '',
      dismissed: dismissed == true,
    );
  }
}

class GestureFailureStore extends ChangeNotifier {
  GestureFailureStore({
    String? Function()? read,
    Future<void> Function(String json)? write,
    DateTime Function()? now,
  })  : _write = write,
        _now = now ?? DateTime.now {
    _load(read);
  }

  /// The newest failures kept; older ones are dropped.
  static const int maxKept = 20;

  /// A longer log keeps its END, where the failure is.
  static const int maxLogChars = 60000;

  final Future<void> Function(String json)? _write;
  final DateTime Function() _now;
  final List<GestureFailure> _all = []; // newest first

  /// Newest first.
  List<GestureFailure> get all => List.unmodifiable(_all);

  /// What Home shows, or null.
  GestureFailure? get newestUndismissed {
    for (final f in _all) {
      if (!f.dismissed) return f;
    }
    return null;
  }

  void _load(String? Function()? read) {
    try {
      final raw = read?.call();
      if (raw == null || raw.isEmpty) return;
      final d = jsonDecode(raw);
      if (d is! List) return;
      for (final e in d) {
        try {
          _all.add(GestureFailure.fromJson(e));
        } catch (_) {} // one bad entry never costs the good ones
      }
      if (_all.length > maxKept) _all.removeRange(maxKept, _all.length);
    } catch (_) {
      _all.clear();
    }
  }

  /// Keep a failure. Null (nothing stored, no notification) when [gestureId] is
  /// already recorded: one failure, one record, however often it is reported.
  Future<GestureFailure?> record({
    required GestureFailureKind kind,
    required String reason,
    required String gestureId,
    String log = '',
    DateTime? at,
  }) async {
    if (_all.any((f) => f.gestureId == gestureId)) return null;
    final f = GestureFailure(
      gestureId: gestureId,
      at: at ?? _now(),
      kind: kind,
      reason: reason,
      log: log.length > maxLogChars
          ? log.substring(log.length - maxLogChars)
          : log,
    );
    _all.insert(0, f);
    if (_all.length > maxKept) _all.removeRange(maxKept, _all.length);
    notifyListeners();
    await _persist();
    return f;
  }

  /// Mark that failure AND every older one dismissed: a dismissed card
  /// supersedes the failures before it, which stay listed and never come back
  /// to Home. An unknown id changes nothing.
  Future<void> dismiss(String gestureId) async {
    final i = _all.indexWhere((f) => f.gestureId == gestureId);
    if (i < 0) return;
    var changed = false;
    for (var j = i; j < _all.length; j++) {
      if (!_all[j].dismissed) {
        _all[j] = _all[j].asDismissed();
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final write = _write;
    if (write == null) return;
    try {
      await write(jsonEncode([for (final f in _all) f.toJson()]));
    } catch (_) {} // the in-memory state stands
  }
}
