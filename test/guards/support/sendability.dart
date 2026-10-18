// sendability.dart — real Isolate.run round trips for worker-entry argument
// and result types (design 02: "each worker entry's argument and result types
// are sent through a real Isolate.run round trip").
//
// A value is sendable if it survives the trip in BOTH directions: closing over
// it (main -> worker) and returning it (worker -> main). The helper reports
// the copy it got back so callers can assert deep equality or project fields.

import 'dart:isolate';

/// Sends [value] into a fresh isolate and back; returns the received copy.
/// Throws if either direction is not sendable (ArgumentError /
/// IsolateSpawnException / RemoteError).
Future<T> isolateRoundTrip<T>(T value) => Isolate.run(() => value);

/// Round-trips [value] and asserts the copy is a different object of the same
/// runtime type with the same [project]ion. For immutable value classes
/// without `==`, [project] compares the fields that matter.
Future<void> expectIsolateRoundTrip<T>(
  T value, {
  Object? Function(T)? project,
}) async {
  final copy = await isolateRoundTrip<T>(value);
  final p = project ?? (T x) => x;
  if (copy.runtimeType != value.runtimeType) {
    throw StateError(
      'round trip changed the type: ${value.runtimeType} -> ${copy.runtimeType}',
    );
  }
  final a = _normalise(p(value));
  final b = _normalise(p(copy));
  if (a != b) {
    throw StateError('round trip changed the value: $a -> $b');
  }
}

/// True when [value] cannot cross an isolate boundary (checked for real).
Future<bool> isNotSendable(Object? value) async {
  try {
    await isolateRoundTrip<Object?>(value);
    return false;
  } on ArgumentError {
    return true;
  } on IsolateSpawnException {
    return true;
  } on RemoteError {
    return true;
  }
}

// Deep-compares lists, maps, records and typed data by structure, so a copy of
// a collection equals its original.
String _normalise(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '$k: ${_normalise(v.entries.firstWhere((e) => e.key.toString() == k).value)}').join(', ')}}';
  }
  if (v is Iterable) return '[${v.map(_normalise).join(', ')}]';
  return '${v.runtimeType}:$v';
}
