// live_stream_buffer.dart — the last 30 s of every live stream, per device.
//
// RAM only (invariant 14): live high-rate streams are never persisted, so this
// file imports no storage and the Live devices screen reads it and nothing
// else. Keyed by (deviceId, streamKey) with streamKey an open string, so a
// stream nobody planned for shows up as a new graph without a UI change.

import 'dart:collection';

class LiveSample {
  const LiveSample(this.at, this.value);
  final DateTime at;
  final double value;
}

/// Times for the beats of one live frame, oldest first. The newest sits at
/// [arrival] and each earlier beat one interval before the beat that followed
/// it, but every beat lands strictly after [after] (the previous beat stored)
/// and after the beat before it in the frame. Frames arrive in batches, so a
/// frame's earlier beats can fall before the last frame's newest; stamped
/// there, [LiveStreamBuffer.add] refuses them and the graph shows a hole where
/// beats were arriving. Placed just after it instead, each keeps its own time.
///
/// The frame's own ts is whole seconds and repeats across a session, so it is
/// no finer than arrival and is not used.
List<DateTime> stampLiveBeats(DateTime arrival, List<int> rrMs,
    {DateTime? after}) {
  final out = List<DateTime>.filled(rrMs.length, arrival);
  var at = arrival;
  for (var i = rrMs.length - 1; i >= 0; i--) {
    out[i] = at;
    at = at.subtract(Duration(milliseconds: rrMs[i]));
  }
  var prev = after;
  for (var i = 0; i < out.length; i++) {
    if (prev != null && !out[i].isAfter(prev)) {
      out[i] = prev.add(const Duration(milliseconds: 1));
    }
    prev = out[i];
  }
  return out;
}

class LiveStreamBuffer {
  LiveStreamBuffer({this.window = const Duration(seconds: 30)});

  final Duration window;

  // device -> stream (insertion ordered, so keys list in first-seen order).
  final Map<String, Map<String, Queue<LiveSample>>> _data = {};

  /// Stores one sample. False when it is older than the stream's newest sample
  /// (dropped: a late frame must not rewind the line). Evicts whatever fell out
  /// of the window relative to the stream's newest sample.
  bool add(String deviceId, String streamKey, DateTime at, double value) {
    final q = (_data[deviceId] ??= {})[streamKey] ??= Queue<LiveSample>();
    if (q.isNotEmpty && at.isBefore(q.last.at)) return false;
    q.addLast(LiveSample(at, value));
    while (q.isNotEmpty && at.difference(q.first.at) >= window) {
      q.removeFirst();
    }
    return true;
  }

  /// The samples still inside the window as of [now] (age strictly < window).
  List<LiveSample> samples(String deviceId, String streamKey,
          {required DateTime now}) =>
      [
        for (final s in _data[deviceId]?[streamKey] ?? const <LiveSample>[])
          if (now.difference(s.at) < window) s,
      ];

  /// What is held, regardless of [now].
  List<LiveSample> retained(String deviceId, String streamKey) =>
      List.unmodifiable(_data[deviceId]?[streamKey] ?? const <LiveSample>[]);

  /// Every stream the device has reported, first seen first. A key stays after
  /// its samples age out, so the screen can say the stream is quiet.
  List<String> streamKeys(String deviceId) =>
      List.unmodifiable(_data[deviceId]?.keys ?? const <String>[]);

  Iterable<String> get deviceIds => _data.keys;

  void clear() => _data.clear();
}
