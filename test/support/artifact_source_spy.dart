// An ArtifactSource spy for the P5 tests. References only symbols that exist
// today, so the "balanced == today" pin compiles and passes before P5.

import 'package:openstrap_edge/state/artifact_warmer.dart';

/// An [ArtifactSource] that records what the warmer asked, and nothing else:
/// `signature` answers from [sigs] and records the key, which is the first thing
/// a warm of that key does (before any cache or database read), so a test can
/// tell "was warmed" without a database round trip.
class AskSource implements ArtifactSource {
  AskSource(this.keys) {
    for (final k in keys) {
      sigs[k] = 'sig-$k';
    }
  }
  final List<String> keys;
  final Map<String, String?> sigs = {};
  final List<List<String>> candidateAsked = [];
  final List<String> signatureAsked = [];

  @override
  Future<List<String>> candidateKeys(List<String> changedDays) async {
    candidateAsked.add([...changedDays]);
    return keys;
  }

  @override
  Future<String?> signature(String key) async {
    signatureAsked.add(key);
    return sigs[key];
  }

  @override
  Future<Map<String, dynamic>?> compute(String key) async => {'k': key};

  bool get warmed => signatureAsked.isNotEmpty;
}
