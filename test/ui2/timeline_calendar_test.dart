import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import '../support/pin_tz.dart';

void main() {
  final zone = Platform.environment['TZ'] ?? 'UTC';
  pinProcessTimeZone(zone);
  // WHY: chart instants use real 23/25h calendar boundaries, including noon.
  // CLAIM(timeline-whole-domain). Catches: midnight + 86400 or noon + 43200.
  test('calendar endpoints match literal UTC, Denver and Kolkata fixtures', () {
    const fixtures = {
      'UTC': [
        (1772928000, 1773014400, 1772971200),
        (1793491200, 1793577600, 1793534400),
      ],
      'America/Denver': [
        (1772953200, 1773036000, 1772992800),
        (1793512800, 1793602800, 1793559600),
      ],
      'Asia/Kolkata': [
        (1772908200, 1772994600, 1772951400),
        (1793471400, 1793557800, 1793514600),
      ],
    };
    expect(
      fixtures.containsKey(zone),
      isTrue,
      reason: 'run with one of the three gate zones',
    );
    for (final (index, day) in ['2026-03-08', '2026-11-01'].indexed) {
      final (start, end, noon) = fixtures[zone]![index];
      expect(localDayStartSec(day), start);
      expect(localDayEndSec(day), end);
      expect(localDayNoonSec(day), noon);
      expect(timelineHome(day), TimelineView(start.toDouble(), end.toDouble()));
    }
    expect(localDayNoonSec('not-a-day'), isNull);
  });
}
