// tasker_moment_export.dart — hands each reviewed moment (a range as ONE item)
// to Tasker as data.
//
// Reuses the OUTBOUND event path: `TaskerBridge.emitEvent` -> channel
// `openstrap/tasker`, method `emit_event` -> NativeChannels.kt sends the
// Android broadcast `<EVENT_ACTION_PREFIX>MOMENT_REVIEWED`. Only on Save, only
// with the Tasker connection on, one broadcast per item, never rate-limited.
//
// Extras (the Kotlin side copies Int, Long, Boolean, String and — added for
// this — Double):
//   kind   String  'moment' | 'range'
//   type   String  MomentChoice.id (pills_meds, nap, caffeine, ..., workout)
//   start  Int     epoch SECONDS of the start minute
//   end    Int     epoch seconds of the end minute — range only, else omitted
//   day    String  local day label of the start, 'YYYY-MM-DD'
//   value  Double  only when the wearer typed an amount; else omitted
// (NativeChannels.kt `emit_event` copies a Double extra — that branch is not
// device-tested.)
// Free text (the Other note, a symptom description) never leaves the app.

import 'package:flutter/foundation.dart';

import '../data/day_label.dart' show dayLabelOf;
import '../gestures/moment_follow_ups.dart';
import '../state/prefs.dart';
import 'tasker_bridge.dart';

class ReviewedItem {
  const ReviewedItem(
      {required this.choice, required this.start, this.end, this.value});
  final MomentChoice choice;
  final DateTime start;

  /// Non-null for a range.
  final DateTime? end;
  final double? value;
}

class TaskerMomentExport {
  /// [connectionOn] null reads the consent: the Tasker connection AND the
  /// separate "Send reviewed moments to Tasker" switch (off by default), both
  /// at send time; nothing is sent while the preferences are not loaded (an
  /// outbound call is never made on a guessed consent). [emit] null calls
  /// `TaskerBridge.emitEvent(event, extras: ..., rateLimited: false,
  /// package: Tasker's)` so only Tasker can receive it.
  TaskerMomentExport({
    bool Function()? connectionOn,
    Future<bool> Function(String event, Map<String, Object> extras)? emit,
  })  : _connectionOn =
            connectionOn ??
                (() =>
                    Prefs.loaded &&
                    Prefs.taskerConnectionOn &&
                    Prefs.taskerMomentExportOn),
        _emit = emit ??
            ((event, extras) => TaskerBridge.emitEvent(event,
                extras: extras,
                rateLimited: false,
                package: TaskerBridge.taskerPackage));

  final bool Function() _connectionOn;
  final Future<bool> Function(String event, Map<String, Object> extras) _emit;

  static const String event = 'MOMENT_REVIEWED';

  static int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

  /// The extras for one item, absent values omitted.
  static Map<String, Object> payloadFor(ReviewedItem i) => {
        'kind': i.end == null ? 'moment' : 'range',
        'type': i.choice.id,
        'start': _sec(i.start),
        if (i.end != null) 'end': _sec(i.end!),
        'day': dayLabelOf(i.start),
        if (i.value != null) 'value': i.value!,
      };

  /// One broadcast per item, in order. Connection off: nothing is sent. A
  /// failed or throwing broadcast never stops the next one and never throws.
  Future<void> exportAll(List<ReviewedItem> items) async {
    for (final i in items) {
      try {
        if (!_connectionOn()) return;
        await _emit(event, payloadFor(i));
      } catch (e) {
        debugPrint('[tasker] moment export failed: $e');
      }
    }
  }
}
