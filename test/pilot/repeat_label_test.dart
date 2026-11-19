// why: owner m244.6 — the repeat button reads in full beside the zoom buttons
// (v22 .ctl: zoom buttons at natural width, days in runs like "Mon–Wed, Fri").
// catches: the zoom buttons squeezing the repeat label to "Mon, T…".
// Real fonts: the test font's square glyphs are far wider than the app's.
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/alarm_screen.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import '../support/bundled_fonts.dart';
import 'screens_test.dart' show pump;

void main(){
  setUpAll(loadFonts);
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();});
  testWidgets('repeat button shows the whole days text at 390 pt',(t)async{
    final day=DateTime(2026,11,23),base=day.millisecondsSinceEpoch~/1000;
    await pump(t,PilotAlarmEditor(alarm:PilotAlarm(id:'a',label:'A',days:{1,2,3,5}),now:day,
      reference:(_)async=>PilotAlarmReference(graph:DayGraph(dayStart:base,hr:List.filled(1440,62),movement:List.filled(1440,.1)),bedMinute:-30,wakeMinute:390,usualSleepMinutes:400),onSave:(_)async{}));
    expect(find.text('Mon–Wed, Fri'),findsOneWidget);
    expect(t.renderObject<RenderParagraph>(find.text('Mon–Wed, Fri')).didExceedMaxLines,false);
    expect(t.takeException(),null);
  });
}
