// demo_route.dart — a plausible local running loop for Demo Mode.
//
// No third-party trail lookup: OpenStrap is local-first (see gps_source.dart's
// own header — "nothing here is uploaded"), and a demo feature is not grounds
// for the app's first outbound call, let alone one that sends someone's
// coordinates to a map service. Instead this takes ONE real fix through the
// same permission-gated path a live run would use ([GpsSource]), then walks a
// closed loop out from it — a route centred on somewhere real, generated
// entirely on-device.
//
// Declining location permission is a normal, expected outcome here (unlike a
// real run, nothing is lost by falling back) — [anchor] returns null and the
// caller uses a fixed neutral anchor instead.

import 'dart:math' as math;

import '../gps/gps_source.dart';
import '../gps/route_models.dart';

class DemoRoute {
  DemoRoute._();

  /// One real GPS fix via the app's normal permission flow, or null if
  /// location is off/denied or no fix arrives within [timeout] — never
  /// throws, never prompts more than the one system dialog [GpsSource]
  /// already owns.
  static Future<GpsSample?> anchor({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final status = await GpsSource.ensurePermission();
    if (status != GpsPermissionStatus.granted) return null;
    try {
      return await GpsSource.stream().first.timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// A procedurally generated closed loop of roughly 3-5 km, anchored at
  /// [origin] (a fixed, clearly-fictional fallback point — central Kansas,
  /// nowhere near anyone — when [anchor] returned nothing), sampled every
  /// [intervalSec] like a real track. Speed eases in over the first ~3 min
  /// and back down over the last ~3, matching a real jog's shape closely
  /// enough that pace/zone screens don't show a suspicious flat line.
  ///
  /// [seed] makes the shape deterministic per call site (e.g. the session's
  /// start time) rather than genuinely random, so a purge-and-regenerate
  /// (demo mode toggled off and back on) doesn't matter for reproducibility
  /// in tests.
  static List<RoutePoint> generateLoop({
    GpsSample? origin,
    required int startTsMs,
    required int durationSec,
    int intervalSec = 5,
    int seed = 0,
  }) {
    final rnd = math.Random(seed);
    final originLat = origin?.lat ?? 38.5;
    final originLng = origin?.lng ?? -98.0;
    final n = (durationSec / intervalSec).floor() + 1;

    const easeSec = 180.0;
    double paceFraction(double tSec) {
      if (tSec < easeSec) return tSec / easeSec;
      final remaining = durationSec - tSec;
      if (remaining < easeSec) return math.max(0.15, remaining / easeSec);
      return 1.0;
    }

    const baseSpeedMps = 2.7; // ~6:10/km jog
    final legs = 6 + rnd.nextInt(3); // rough hexagon/heptagon block loop
    final radiusM = 250.0 + rnd.nextDouble() * 250.0;
    final legLenM = (2 * math.pi * radiusM) / legs;
    const metersPerDegLat = 111320.0;
    final metersPerDegLng = 111320.0 * math.cos(originLat * math.pi / 180);

    final pts = <RoutePoint>[];
    var sinceTurn = 0.0;
    var bearing = rnd.nextDouble() * 2 * math.pi;
    var lat = originLat, lng = originLng;
    for (var i = 0; i < n; i++) {
      final tSec = (i * intervalSec).toDouble();
      final speed = baseSpeedMps *
          paceFraction(tSec) *
          (0.95 + rnd.nextDouble() * 0.1); // small per-fix jitter
      final stepM = speed * intervalSec;
      if (sinceTurn >= legLenM) {
        bearing += 2 * math.pi / legs;
        sinceTurn = 0;
      }
      sinceTurn += stepM;
      lat += (stepM * math.cos(bearing)) / metersPerDegLat;
      lng += (stepM * math.sin(bearing)) / metersPerDegLng;
      pts.add(RoutePoint(
        seq: i,
        tsMs: startTsMs + (tSec * 1000).round(),
        lat: lat,
        lng: lng,
        alt: 250 + 6 * math.sin(tSec / 90),
        accuracy: 5 + rnd.nextDouble() * 6,
        speed: speed,
      ));
    }
    return pts;
  }
}
