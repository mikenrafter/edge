import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';

void main() {
  // WHY/CLAIM(pulse-evidence): a long recording must declare omissions, retain
  // both ends and stay within the shipped 20,000-beat / 1 MiB per-revision cap.
  test(
    'bounded evidence preserves ends and declares partial retained ranges',
    () async {
      final beats = [
        for (var i = 0; i < 24001; i++)
          <String, dynamic>{
            'id': 'b$i',
            'source': 'strap',
            'time': (i + 1) * 1000,
            'index': i,
            'raw': 1000.0,
            'value': 1000.0,
            'change': i == 0 ? null : 0.0,
            'predecessor': i == 0 ? null : 'b${i - 1}',
            'pair': null,
            'threshold': 100.0,
            'baseline': 1000.0,
            'class': 'normal',
            'plausible': true,
            'retained': true,
            'corrected': false,
            'dropped': false,
            'feature': true,
            'adjacent': i > 0,
            'labels': <String>[],
          },
      ];
      final input = <String, dynamic>{
        'id': 'strap:0',
        'source': 'strap',
        'start': 0,
        'end': 24002000,
        'ongoing': false,
        'version': 1,
        'alertEligible': true,
        'beats': beats,
        'context': beats,
        'windows': <dynamic>[],
        'heartRate': <dynamic>[],
      };
      final encoded = await Isolate.run(() => encodePulseEvidenceHeavy(input));
      final bytes = (encoded['payload'] as List).cast<int>();
      final doc = jsonDecode(utf8.decode(gzip.decode(bytes))) as Map;
      expect(bytes.length, lessThanOrEqualTo(1024 * 1024));
      expect(doc['partial'], true);
      final retained = doc['beats'] as List;
      expect(retained.length, 20000);
      expect(retained.first['time'], 1000);
      expect(retained.last['time'], 24001000);
      expect(doc['omissions'], isNotEmpty);
    },
  );
}
