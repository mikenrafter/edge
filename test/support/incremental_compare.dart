import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// Reuse built from exact algebra (running sums, appended counts, cached
/// unchanged results) may differ from the batch oracle only by floating-point
/// regrouping, so it is held to this relative error.
const kExactRelTol = 1e-9;

/// For an approximation that is accurate by design rather than exact. Nothing
/// in the app uses one yet; a reuse path that needs it must say so in its test.
const kApproxRelTol = 0.02;

/// Below this magnitude a relative bound is meaningless (zero has no scale), so
/// values are compared absolutely.
const kAbsFloor = 1e-12;

/// `|actual - expected| <= max(kAbsFloor, rel * |expected|)`; NaN matches NaN
/// and infinities must be equal.
void expectRelClose(
  num actual,
  num expected, {
  double rel = kExactRelTol,
  String? reason,
}) {
  final a = actual.toDouble(), e = expected.toDouble();
  if (e.isNaN) {
    expect(a.isNaN, isTrue, reason: reason);
  } else if (e.isInfinite) {
    expect(a, e, reason: reason);
  } else {
    expect(a, closeTo(e, math.max(kAbsFloor, rel * e.abs())), reason: reason);
  }
}

/// Deep JSON-shaped equality with [expectRelClose] on every number.
void expectSameJson(
  Object? actual,
  Object? expected, {
  double rel = kExactRelTol,
  String path = r'$',
}) {
  if (actual is num && expected is num) {
    expectRelClose(actual, expected, rel: rel, reason: path);
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final a = actual as Map;
    expect(a.keys.toSet(), expected.keys.toSet(), reason: '$path keys');
    for (final key in expected.keys) {
      expectSameJson(a[key], expected[key], rel: rel, path: '$path.$key');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final a = actual as List;
    expect(a.length, expected.length, reason: '$path length');
    for (var i = 0; i < expected.length; i++) {
      expectSameJson(a[i], expected[i], rel: rel, path: '$path[$i]');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}
