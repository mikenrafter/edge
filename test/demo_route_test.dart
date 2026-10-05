import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/demo/demo_route.dart';
import 'package:openstrap_edge/gps/route_models.dart';

void main() {
  test('demo route coordinates and timestamps reproduce for fixed input', () {
    final first = DemoRoute.generateLoop(
      startTsMs: 1000000,
      durationSec: 1800,
      seed: 7,
    );
    final second = DemoRoute.generateLoop(
      startTsMs: 1000000,
      durationSec: 1800,
      seed: 7,
    );
    expect(
      first.map((p) => p.toRow('fixture')).toList(),
      second.map((p) => p.toRow('fixture')).toList(),
    );
    expect(first, hasLength(361));
    for (var i = 0; i < first.length; i++) {
      expect(first[i].seq, i);
      expect(first[i].tsMs, 1000000 + i * 5000);
      expect(first[i].lat.isFinite, true);
      expect(first[i].lng.isFinite, true);
      expect(first[i].lat, inInclusiveRange(37.5, 39.5));
      expect(first[i].lng, inInclusiveRange(-99, -97));
      expect(first[i].speed, inInclusiveRange(0, 3));
    }
  });
  test(
    'route uses supplied fictional origin without changing sample timing',
    () {
      const origin = GpsSample(lat: 40, lng: -100, tsMs: 55);
      final points = DemoRoute.generateLoop(
        origin: origin,
        startTsMs: 5000,
        durationSec: 12,
        intervalSec: 5,
        seed: 3,
      );
      expect(points.map((p) => p.tsMs), [5000, 10000, 15000]);
      expect(points.first.lat, 40);
      expect(points.first.lng, -100);
      expect(points.last.lat, closeTo(40, .01));
      expect(points.last.lng, closeTo(-100, .01));
    },
  );
  test(
    'changing session timestamp preserves geometry and shifts absolute times',
    () {
      final a = DemoRoute.generateLoop(startTsMs: 0, durationSec: 60, seed: 1);
      final b = DemoRoute.generateLoop(
        startTsMs: 900000,
        durationSec: 60,
        seed: 1,
      );
      for (var i = 0; i < a.length; i++) {
        expect((a[i].lat, a[i].lng), (b[i].lat, b[i].lng));
        expect(b[i].tsMs - a[i].tsMs, 900000);
      }
    },
  );
}
