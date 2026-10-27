import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';

void main() {
  final noon = DateTime(2026, 10, 1, 12).millisecondsSinceEpoch ~/ 1000;
  const moment = MomentLabel(date:'2026-10-01', hhmm:'12:00', label:'meal',
      note:'With friends', answeredAtMs:1);
  test('existing timed nutrition and confirmed meal form one identified row', () {
    final rows = dayMoments(timeline: {}, meals: [FoodEntry(id:'lunch',
        date:'2026-10-01', meal:'lunch', label:'Rice bowl', atTs:noon + 15,
        kcal:550, proteinG:20)], momentLabels: [moment]);
    expect(rows, hasLength(1));
    expect(rows.single.identity, 'moment:2026-10-01 12:00');
    expect(rows.single.title, 'Rice bowl');
    expect(rows.single.detail, contains('550 kcal'));
    expect(rows.single.detail, contains('With friends'));
    expect(rows.single.at, noon + 15);
  });
  test('a nearby or untimed food entry is not guessed to match the moment', () {
    final rows = dayMoments(timeline: {}, meals: [FoodEntry(id:'lunch',
        date:'2026-10-01', meal:'lunch', label:'Rice bowl', atTs:noon + 60,
        kcal:550), const FoodEntry(id:'snack',date:'2026-10-01', meal:'snack',
        label:'Apple')], momentLabels: [moment]);
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.title), containsAll(['Rice bowl','Meal']));
  });
}
