// A scriptable ArtifactSource for the warmer tests. See calc_warmer_test.dart for
// the API (lib/state/artifact_warmer.dart). This file references the class
// directly: it cannot be reached through `dynamic` (it is a class the tests
// construct and AppState owns).

import 'dart:async';

import 'package:openstrap_edge/state/artifact_warmer.dart';

class FakeArtifactSource implements ArtifactSource {
  /// What [candidateKeys] answers, in order.
  List<String> keys = const [];

  /// The current signature per key (absent / null => no signature).
  final Map<String, String?> sigs = {};

  /// The value [compute] returns per key (absent => `{'k': key}`); a null
  /// entry means "nothing to store".
  final Map<String, Map<String, dynamic>?> results = {};
  final Set<String> nullResult = {};

  /// Keys whose compute / signature throw.
  final Set<String> computeThrows = {};
  final Set<String> sigThrows = {};

  /// Keys whose compute waits for the matching completer.
  final Map<String, Completer<void>> gates = {};

  // What happened.
  final List<List<String>> candidateCalls = [];
  final List<String> computeStarted = [];
  final List<String> computeFinished = [];
  int running = 0;
  int maxRunning = 0;

  /// Runs synchronously inside every [candidateKeys] call.
  void Function()? onAsk;

  /// Runs inside every [compute] before it finishes (e.g. flip a hold flag).
  void Function(String key)? onCompute;

  int computes(String key) => computeStarted.where((k) => k == key).length;

  @override
  Future<List<String>> candidateKeys(List<String> changedDays) async {
    candidateCalls.add([...changedDays]);
    onAsk?.call();
    return keys;
  }

  @override
  Future<String?> signature(String key) async {
    if (sigThrows.contains(key)) throw StateError('sig $key');
    return sigs[key];
  }

  @override
  Future<Map<String, dynamic>?> compute(String key) async {
    computeStarted.add(key);
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      onCompute?.call(key);
      final g = gates[key];
      if (g != null) await g.future;
      if (computeThrows.contains(key)) throw StateError('compute $key');
      if (nullResult.contains(key)) return null;
      return results[key] ?? {'k': key};
    } finally {
      running--;
      computeFinished.add(key);
    }
  }
}
