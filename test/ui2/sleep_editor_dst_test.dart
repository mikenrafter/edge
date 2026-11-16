// WHY: CLAIM(sleep-editor-night-region). A fixed 1440-minute domain drops
// the end of a fall-back night and reaches into the next day in spring.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import '../support/pin_tz.dart';

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) async => {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String day) async => {'naps': <Object>[]};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String day) async => {'sleep_source': 'manual'};
}

void main() {
  pinProcessTimeZone("${Platform.environment['TZDIR'] ?? '/usr/share/zoneinfo'}/America/Denver");
  test('fall-back night loads all 1500 elapsed minutes to the next local evening', () async {
    final d = await SleepEditorData.load(_Repo(), '2026-11-01');
    expect(d.hr.length, 1500);
    expect(d.movement.length, 1500);
    expect(d.domainEnd - d.domainStart, 25 * 3600);
    expect(DateTime.fromMillisecondsSinceEpoch(d.domainEnd * 1000), DateTime(2026, 11, 1, 12));
    expect(d.mainSource, 'manual');
  });
  test('spring-forward night loads 1380 elapsed minutes to the next local evening', () async {
    final d = await SleepEditorData.load(_Repo(), '2026-03-08');
    expect(d.hr.length, 1380);
    expect(d.domainEnd - d.domainStart, 23 * 3600);
    expect(DateTime.fromMillisecondsSinceEpoch(d.domainEnd * 1000), DateTime(2026, 3, 8, 12));
  });
}
