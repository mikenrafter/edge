// spectral_zone.dart - the calendar the spectral archive turns a day label into
// an absolute window with. Production is the device's LOCAL zone (day_label.dart,
// DST-aware); the seam lets tests fix a zone (Denver, then New York).
import 'day_label.dart';

class SpectralZone {
  const SpectralZone(this.startOf, this.endOf, this.dayOf);

  final int Function(String dayId) startOf;
  final int Function(String dayId) endOf;
  final String Function(int epochSec) dayOf;

  /// The device's local zone.
  static final SpectralZone local = SpectralZone(
    (d) => localDayStartSec(d)!,
    (d) => localDayEndSec(d)!,
    (t) => dayLabelOf(DateTime.fromMillisecondsSinceEpoch(t * 1000)),
  );

  /// The zone in force. Tests replace it and restore [local] afterwards.
  static SpectralZone current = local;

  /// A fixed UTC offset (seconds east of UTC; Denver MDT is -6 * 3600).
  factory SpectralZone.fixedOffset(int offsetSec) {
    int utcMidnight(String d) {
      final p = d.split('-').map(int.parse).toList();
      return DateTime.utc(p[0], p[1], p[2]).millisecondsSinceEpoch ~/ 1000;
    }

    return SpectralZone(
      (d) => utcMidnight(d) - offsetSec,
      (d) => utcMidnight(d) - offsetSec + 86400,
      (t) {
        final u = DateTime.fromMillisecondsSinceEpoch((t + offsetSec) * 1000,
            isUtc: true);
        String two(int n) => n.toString().padLeft(2, '0');
        return '${u.year}-${two(u.month)}-${two(u.day)}';
      },
    );
  }
}
