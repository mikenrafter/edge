// tasker_moment_export.dart — hands each reviewed moment (a range as ONE item)
// to Tasker as data. RED stubs.
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
// Free text (the Other note, a symptom description) never leaves the app.

import '../gestures/moment_follow_ups.dart';

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
  /// [connectionOn] null reads `Prefs.taskerConnectionOn`. [emit] null calls
  /// `TaskerBridge.emitEvent(event, extras: ..., rateLimited: false)`.
  TaskerMomentExport({
    bool Function()? connectionOn,
    Future<bool> Function(String event, Map<String, Object> extras)? emit,
  });

  static const String event = 'MOMENT_REVIEWED';

  /// The extras for one item, absent values omitted.
  static Map<String, Object> payloadFor(ReviewedItem i) =>
      throw UnimplementedError('RED stub');

  /// One broadcast per item, in order. Connection off: nothing is sent. A
  /// failed or throwing broadcast never stops the next one and never throws.
  Future<void> exportAll(List<ReviewedItem> items) =>
      throw UnimplementedError('RED stub');
}
