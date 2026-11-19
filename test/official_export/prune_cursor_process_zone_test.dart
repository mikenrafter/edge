// The PRODUCTION calendar (`DayLabelCalendar`, the canonical day_label.dart API
// in the process zone) in the three zones the persistence checklist names.
//
// WHY: prune_cursor_test.dart proves the rule with a zone-database calendar; the
// exporter will run with the device's process zone, so the real wrapper must agree
// with the same independent literals when the process zone is moved. The host
// may lack tzdata (Boat's did not apply `TZ=America/Denver`), so the zones are
// POSIX rule strings, which need no database: Denver is `MST7MDT,M3.2.0,M11.1.0`
// (DST from the second Sunday of March to the first Sunday of November, the same
// rule as the independent literals below for 2026). CLAIM(official-export-prune-edge).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/prune_cursor.dart';
import 'process_zone.dart';

// zone -> (input instant, next local midnight at or after it), literals from an
// independent zone database.
const _posix = {
  'UTC': 'UTC0',
  'America/Denver': 'MST7MDT,M3.2.0,M11.1.0',
  'Asia/Kolkata': 'IST-5:30',
  'America/Santiago': '<-04>4<-03>,M9.1.6/24,M4.1.6/24',
  'America/Havana': 'CST5CDT,M3.2.0/0,M11.1.0/1',
  'America/Sao_Paulo': '<-03>3<-02>,M11.1.0/0,M2.3.0/0',
};

const _cases = <String, List<(int, int)>>{
  // Missing midnight normalizes to 01:00; repeated midnight uses day start.
  'America/Santiago': [(1788667199, 1788667200), (1788667200, 1788667200), (1788667201, 1788750000)],
  'America/Havana': [(1793505600, 1793505600), (1793505601, 1793595600)],
  'America/Sao_Paulo': [(1541300399, 1541300400), (1541300400, 1541300400)],
  'UTC': [(1792454400, 1792454400), (1792454401, 1792540800), (1792497600, 1792540800)],
  'America/Denver': [
    (1792476000, 1792476000), // exactly local midnight
    (1792476001, 1792562400),
    (1792519200, 1792562400), // noon
    (1793514600, 1793602800), // fall-back day, 25 h
    (1772962200, 1773036000), // spring-forward day, 23 h
  ],
  'Asia/Kolkata': [(1792434600, 1792434600), (1792434601, 1792521000), (1792477800, 1792521000)],
};

void main() {
  final originalZone = Platform.environment['TZ'];
  tearDown(() => setProcessZone(originalZone));
  for (final e in _cases.entries) {
    test('${e.key}: DayLabelCalendar matches the independent literals', () {
      setProcessZone(_posix[e.key]);
      if (e.key == 'Asia/Kolkata') {
        expect(DateTime.utc(2026, 7, 1).toLocal().timeZoneOffset, const Duration(hours: 5, minutes: 30));
      }
      for (final (input, want) in e.value) {
        expect(const DayLabelCalendar().midnightAtOrAfter(input), want, reason: '${e.key} $input');
      }
    });
  }
}
