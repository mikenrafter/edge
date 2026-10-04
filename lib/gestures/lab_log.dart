// lab_log.dart — what the Device lab remembers: band events with both clocks,
// and the step-by-step trace of a multi-tap session (ECG touches or repeated
// double taps). RAM only, bounded, never persisted (nothing here is a
// measurement).
//
// Every trace line carries its wall time to the millisecond, the time since the
// session's tap and the time since the previous line, so a slow stage is visible
// without arithmetic. A session ends with a one-line summary (method, settings,
// result, total time). [labLogText] turns the whole lab into plain text for the
// "Save lab log file" button.
//
// ECG packets (8V). Every live R17 packet a gesture or a hardware probe sees
// is kept here too, raw samples and the band's status bytes, so a session can
// be replayed off the band (test/support/ecg_trace.dart) and the sensor's
// timing studied. They are live high-rate data: RAM only, bounded, gone on
// restart or Clear, and they leave the phone only when the user copies the
// log (invariant 14). One line per packet, see [labPacketLine].

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import 'device_action.dart';
import 'gesture_dispatcher.dart';
import 'strap_event.dart';
import 'tap_names.dart';

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

/// One kept ECG packet: what the band sent and when the phone got it.
class LabPacket {
  const LabPacket({
    required this.tag,
    required this.receivedAt,
    required this.strapSeconds,
    required this.subseconds,
    required this.flags,
    required this.s2State,
    required this.progress,
    required this.quality,
    required this.unreadable,
    required this.samples,
  });

  factory LabPacket.of(LabradorR17 r, DateTime receivedAt, String tag) =>
      LabPacket(
        tag: tag,
        receivedAt: receivedAt,
        strapSeconds: r.strapSeconds,
        subseconds: r.subseconds,
        flags: r.flags.raw,
        s2State: r.s2State,
        progress: r.progress,
        quality: r.quality,
        unreadable: r.unreadable.raw,
        samples: Int16List.fromList(r.samples),
      );

  /// Which session or probe it belongs to, e.g. `tap 18:17:57.367`.
  final String tag;
  final DateTime receivedAt;
  final int strapSeconds, subseconds;
  final int flags, s2State, progress, quality, unreadable;
  final Int16List samples;
}

/// The packet line format, version 1. Fields are space separated `key=value`;
/// `tag` runs to the ` | `. `b64` is the samples as little-endian int16,
/// base64, or `0` when every sample is zero (most packets before contact).
///
///     r17v1 tag=tap 18:17:57.367 | recv=1790986679251 sec=1790986679
///       sub=31785 flags=0a s2=1 progress=3 quality=0 unreadable=00 n=100 b64=...
const String labPacketFormat =
    'r17v1 tag=<session> | recv=<phone ms since epoch> sec=<strap seconds> '
    'sub=<1/32768 s> flags=<hex> s2=<n> progress=<n> quality=<n> '
    'unreadable=<hex> n=<samples> b64=<int16 LE samples, base64; 0 = all zero>';

String labPacketLine(LabPacket p) {
  final allZero = p.samples.every((v) => v == 0);
  final b64 = allZero
      ? '0'
      : base64.encode(p.samples.buffer
          .asUint8List(p.samples.offsetInBytes, p.samples.lengthInBytes));
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return 'r17v1 tag=${p.tag} | recv=${p.receivedAt.millisecondsSinceEpoch} '
      'sec=${p.strapSeconds} sub=${p.subseconds} flags=${hex(p.flags)} '
      's2=${p.s2State} progress=${p.progress} quality=${p.quality} '
      'unreadable=${hex(p.unreadable)} n=${p.samples.length} b64=$b64';
}

/// The whole lab as plain text. [steps], [sessions] and [entries] are newest
/// first (as the screen shows them); the text reads oldest first. [packets]
/// are oldest first.
String labLogText({
  required List<DeviceLabEntry> entries,
  required List<String> steps,
  required List<String> sessions,
  List<LabPacket> packets = const [],
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
  b
    ..writeln()
    ..writeln('ECG packets, oldest first')
    ..writeln('  format: $labPacketFormat');
  if (packets.isEmpty) b.writeln('  No ECG packets yet.');
  for (final p in packets) {
    b.writeln('  ${labPacketLine(p)}');
  }
  return b.toString();
}

/// The newest-first rolling log the Device lab screen reads.
class DeviceLabLog extends ChangeNotifier {
  static const int maxEntries = 60;

  /// A 20 s session logs about one line per packet plus the stages.
  static const int maxSteps = 400;
  static const int maxSessions = 10;

  /// About six minutes of stream: a few gestures and a probe or two.
  static const int maxPackets = 360;

  /// A band reply to a buzz can arrive a moment after the session ended; it is
  /// still part of that session's story.
  static const Duration traceGrace = Duration(seconds: 5);

  final List<DeviceLabEntry> _entries = [];
  final List<String> _steps = [];
  final List<String> _sessions = [];
  final List<LabPacket> _packets = []; // oldest first

  bool _open = false;
  String _method = '', _settings = '';
  DateTime? _tapAt, _lastAt, _endedAt;

  /// Newest first.
  List<DeviceLabEntry> get entries => List.unmodifiable(_entries);

  /// Newest first, each already formatted by [labLine].
  List<String> get steps => List.unmodifiable(_steps);

  /// One summary per finished session, newest first.
  List<String> get sessionSummaries => List.unmodifiable(_sessions);

  /// Kept ECG packets, oldest first.
  List<LabPacket> get packets => List.unmodifiable(_packets);

  /// The tag for packets of the current (or last) session.
  String get sessionTag {
    final tap = _tapAt;
    return tap == null ? 'none' : '${_method == 'ECG sensor touches' ? 'tap' : _method} ${labClock(tap)}';
  }

  /// Keep one ECG packet. [tag] defaults to the current session's.
  void addPacket(LabradorR17 r, DateTime receivedAt, {String? tag}) {
    _packets.add(LabPacket.of(r, receivedAt, tag ?? sessionTag));
    if (_packets.length > maxPackets) _packets.removeAt(0);
  }

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

  /// Close the session with its result: [count] taps (an ECG session names it,
  /// "Double tap + 2 ECG taps"), or [reason] when it was
  /// abandoned, or [result] verbatim (a hardware probe). Adds the summary and a
  /// final line. A second call, or one with no session, does nothing.
  void endSession({int? count, String? reason, String? result, DateTime? at}) {
    if (!_open) return;
    final end = at ?? DateTime.now();
    final tap = _tapAt ?? end;
    final seconds =
        (end.difference(tap).inMilliseconds / 1000).toStringAsFixed(1);
    // An ECG session's count is named (8AK C); for repeated double taps it is
    // the number of double taps in a row, still "N taps".
    final outcome = result ??
        (count != null
            ? (_method == 'ECG sensor touches'
                ? ecgTapCountName(count)
                : '$count taps')
            : 'abandoned (${reason ?? 'unknown'})');
    final summary = '$_method | $_settings | $outcome | $seconds s in total';
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

  /// The whole lab as plain text for the clipboard. [withPackets] false leaves
  /// the raw ECG packets out (a failure record keeps the trace, not the stream).
  String toPlainText({DateTime? at, bool withPackets = true}) => labLogText(
        entries: _entries,
        steps: _steps,
        sessions: _sessions,
        packets: withPackets ? _packets : const [],
        at: at,
      );

  void clear() {
    _entries.clear();
    _packets.clear();
    _steps.clear();
    _sessions.clear();
    _open = false;
    _tapAt = _lastAt = _endedAt = null;
    notifyListeners();
  }
}
