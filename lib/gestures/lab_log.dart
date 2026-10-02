// lab_log.dart — what the Device lab remembers: band events with both clocks,
// and the step-by-step trace of a multi-tap session (ECG touches or repeated
// double taps). RAM only, bounded, never persisted (nothing here is a
// measurement).
//
// Every trace line carries its wall time to the millisecond, the time since the
// session's tap and the time since the previous line, so a slow stage is visible
// without arithmetic. A session ends with a one-line summary (method, settings,
// result, total time). [labLogText] turns the whole lab into plain text for the
// "Copy all logs" button.

import 'package:flutter/foundation.dart';

import 'device_action.dart';
import 'gesture_dispatcher.dart';
import 'strap_event.dart';

/// One band event as the lab shows it: when it happened (the band's clock when
/// believable), when the phone got it, and which actions ran.
class DeviceLabEntry {
  const DeviceLabEntry({
    required this.eventId,
    required this.eventTime,
    required this.receivedAt,
    required this.live,
    this.actions = const [],
  });

  factory DeviceLabEntry.fromEvent(StrapEvent e,
          {List<GestureOutcome> outcomes = const []}) =>
      DeviceLabEntry(
        eventId: e.eventId,
        eventTime: e.effectiveTime,
        receivedAt: e.receivedAt,
        live: e.isLive,
        actions: [
          for (final o in outcomes)
            if (o.status == GestureStatus.ran) o.action.id,
        ],
      );

  final int eventId;
  final DateTime eventTime;
  final DateTime receivedAt;
  final bool live;

  /// Ids of the actions that ran for this event.
  final List<String> actions;

  Duration get delay => receivedAt.difference(eventTime);

  /// Seconds to a tenth: "1.2 s".
  String get delayLabel =>
      '${(delay.inMilliseconds / 1000).toStringAsFixed(1)} s';
}

/// Local `HH:mm:ss.SSS`.
String labClock(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}.'
      '${l.millisecond.toString().padLeft(3, '0')}';
}

/// "09:15:03.250 | tap +1210 ms | last +1200 ms | text". Outside a session
/// there is no tap to measure from: "tap n/a".
String labLine(DateTime at, int? sinceTapMs, int sinceLastMs, String text) =>
    '${labClock(at)} | tap ${sinceTapMs == null ? 'n/a' : '+$sinceTapMs ms'} '
    '| last +$sinceLastMs ms | $text';

/// One band event as plain text, for copying.
String labEntryText(DeviceLabEntry e) => [
      'Event ${e.eventId} | ${e.live ? 'Live' : 'Late'} | ${e.delayLabel} '
          'after it happened',
      '  Happened ${labClock(e.eventTime)}',
      '  Received ${labClock(e.receivedAt)}',
      if (e.actions.isNotEmpty) '  Ran ${e.actions.join(', ')}',
    ].join('\n');

/// The whole lab as plain text. [steps], [sessions] and [entries] are newest
/// first (as the screen shows them); the text reads oldest first.
String labLogText({
  required List<DeviceLabEntry> entries,
  required List<String> steps,
  required List<String> sessions,
  DateTime? at,
}) {
  final b = StringBuffer()
    ..writeln('OpenStrap Device lab log')
    ..writeln('Copied ${(at ?? DateTime.now()).toLocal().toIso8601String()}')
    ..writeln()
    ..writeln('Sessions');
  if (sessions.isEmpty) b.writeln('  No sessions yet.');
  for (final s in sessions.reversed) {
    b.writeln('  $s');
  }
  b
    ..writeln()
    ..writeln('Log, oldest first');
  if (steps.isEmpty) b.writeln('  No log lines yet.');
  for (final s in steps.reversed) {
    b.writeln('  $s');
  }
  b
    ..writeln()
    ..writeln('Band events, oldest first');
  if (entries.isEmpty) b.writeln('  No band events yet.');
  for (final e in entries.reversed) {
    b.writeln(labEntryText(e).split('\n').map((l) => '  $l').join('\n'));
  }
  return b.toString();
}

/// The newest-first rolling log the Device lab screen reads.
class DeviceLabLog extends ChangeNotifier {
  static const int maxEntries = 60;

  /// A 20 s session logs about one line per packet plus the stages.
  static const int maxSteps = 400;
  static const int maxSessions = 10;

  /// A band reply to a buzz can arrive a moment after the session ended; it is
  /// still part of that session's story.
  static const Duration traceGrace = Duration(seconds: 5);

  final List<DeviceLabEntry> _entries = [];
  final List<String> _steps = [];
  final List<String> _sessions = [];

  bool _open = false;
  String _method = '', _settings = '';
  DateTime? _tapAt, _lastAt, _endedAt;

  /// Newest first.
  List<DeviceLabEntry> get entries => List.unmodifiable(_entries);

  /// Newest first, each already formatted by [labLine].
  List<String> get steps => List.unmodifiable(_steps);

  /// One summary per finished session, newest first.
  List<String> get sessionSummaries => List.unmodifiable(_sessions);

  /// True while a session runs and for [traceGrace] after it. Band replies to a
  /// buzz are added to the trace only then.
  bool tracingAt(DateTime now) {
    if (_open) return true;
    final ended = _endedAt;
    return ended != null && now.difference(ended) <= traceGrace;
  }

  void addEntry(DeviceLabEntry e) {
    _entries.insert(0, e);
    if (_entries.length > maxEntries) _entries.removeLast();
    notifyListeners();
  }

  /// A session begins at the phone's receipt of its tap ([tapAt]); every line
  /// until the next session is measured from it.
  void beginSession({
    required String method,
    required String settings,
    required DateTime tapAt,
    DateTime? at,
  }) {
    _open = true;
    _method = method;
    _settings = settings;
    _tapAt = tapAt;
    _endedAt = null;
    _lastAt = at ?? DateTime.now();
    notifyListeners();
  }

  /// Close the session with its result: [count] taps, or [reason] when it was
  /// abandoned. Adds the summary and a final line. A second call, or one with no
  /// session, does nothing.
  void endSession({int? count, String? reason, DateTime? at}) {
    if (!_open) return;
    final end = at ?? DateTime.now();
    final tap = _tapAt ?? end;
    final seconds =
        (end.difference(tap).inMilliseconds / 1000).toStringAsFixed(1);
    final result =
        count != null ? '$count taps' : 'abandoned (${reason ?? 'unknown'})';
    final summary = '$_method | $_settings | $result | $seconds s in total';
    _sessions.insert(0, summary);
    if (_sessions.length > maxSessions) _sessions.removeLast();
    addStep('Session ended: $summary', at: end);
    _open = false;
    _endedAt = end;
  }

  void addStep(String line, {DateTime? at}) {
    final t = at ?? DateTime.now();
    final tap = _tapAt;
    final last = _lastAt;
    _steps.insert(
      0,
      labLine(
        t,
        tap == null ? null : t.difference(tap).inMilliseconds,
        last == null ? 0 : t.difference(last).inMilliseconds,
        line,
      ),
    );
    if (_steps.length > maxSteps) _steps.removeLast();
    _lastAt = t;
    notifyListeners();
  }

  /// The whole lab as plain text for the clipboard.
  String toPlainText({DateTime? at}) => labLogText(
        entries: _entries,
        steps: _steps,
        sessions: _sessions,
        at: at,
      );

  void clear() {
    _entries.clear();
    _steps.clear();
    _sessions.clear();
    _open = false;
    _tapAt = _lastAt = _endedAt = null;
    notifyListeners();
  }
}
