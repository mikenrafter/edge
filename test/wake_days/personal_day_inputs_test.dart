import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';

void main() {
  final onset = DateTime(2026, 11, 2, 23);
  final up = DateTime(2026, 11, 3, 7);
  final sec = up.millisecondsSinceEpoch ~/ 1000;
  // WHY: naps cannot be main-sleep boundary inputs. catches: accepting all rows.
  test('the read boundary rejects naps and malformed windows', () {
    final rows = mainSleepsOf([
      {'onset_ts': onset.millisecondsSinceEpoch ~/ 1000, 'wake_ts': sec},
      {'kind': 'nap', 'onset_ts': sec, 'wake_ts': sec+3600},
      {'onset_ts': sec+100, 'wake_ts': sec},
      {'onset_ts': null},
    ]);
    expect(rows.map((s) => (s.onset, s.wake)), [(onset, up)]);
  });
  // WHY: a buzz is a prompt; the owner may still be asleep in bed.
  // catches: naturalWake raw evidence becoming proof of wakefulness.
  test('Natural Wake buzz alone never turns over the day', () {
    final wakes = personalWakesOf(onset, [{'kind': 'naturalWake', 'at_sec': sec}]);
    expect(wakes, isEmpty);
    expect(personalDayAwake([MainSleep(onset, null)], wakes, up), isFalse);
  });
  test('acknowledgement movement alarm-fired and confirmed wakes count', () {
    for (final kind in ['alarmAcknowledged', 'bandMovement', 'alarmFired']) {
      final wakes = personalWakesOf(onset, [{'kind': kind, 'at_sec': sec}]);
      expect(wakes.map((w) => w.at), [up], reason: kind);
    }
    expect(personalWakesOf(onset, [], confirmedAtSec: sec).single.at, up);
    expect(personalWakesOf(onset, [{'kind': 'appOpened', 'at_sec': sec}]), isEmpty);
  });
}
