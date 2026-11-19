import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/sync_strip.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/header_rows_fakes.dart';

final now=DateTime(2026,11,19,10,30);
class _Repo extends LocalRepository {
  final days=<String>[];
  bool fail=false;
  @override Future<int> pendingActivityCount()async=>2;
  @override Future<List<ActivitySuggestion>> pendingActivities()async=>[
    ActivitySuggestion(id:'nap',kind:ActivityKind.nap,startTs:now.subtract(const Duration(hours:8)).millisecondsSinceEpoch~/1000,endTs:now.subtract(const Duration(hours:7)).millisecondsSinceEpoch~/1000,revision:1),
    ActivitySuggestion(id:'walk',kind:ActivityKind.workout,startTs:now.subtract(const Duration(hours:9)).millisecondsSinceEpoch~/1000,endTs:now.subtract(const Duration(hours:8)).millisecondsSinceEpoch~/1000,revision:1,details:const {'sport':'walking'}),
  ];
  @override Future<Map<String,dynamic>> getDayTimeline(String date)async{
    days.add(date);if(fail)throw StateError('read failed');
    return {'date':date,'day_start':localDayStartSec(date),'hr':[{'t':localDayStartSec(date)!+19*3600,'v':67}]};
  }
}
class _App extends HeaderApp {
  _App(this.store):super(through:now.subtract(const Duration(hours:6))){device.dataRangeNewest=now.millisecondsSinceEpoch~/1000;}
  final _Repo store;
  @override LocalRepository get repo=>store;
}
Future<void> settleReads(WidgetTester t)async{
  await t.runAsync(()async{await Future<void>.value();});
  await t.pump();await t.pump();await t.pump();
}
void main(){
  setUp(()async{SharedPreferences.setMockInitialValues({'pilot.sync_strip':true});await Prefs.reload();});
  // why: Home must read both calendar days in its backlog-relative window.
  // catches: a fixed-today read losing the pre-midnight HR or ignoring band state.
  testWidgets('real card loads previous day and responds to the durable edge', (t)async{
    await withClock(Clock.fixed(now),()async{
      final repo=_Repo();
      final state=_App(repo);
      await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value:state,child:MaterialApp(theme:buildTheme(Brightness.dark),home:const Scaffold(body:DetectedActivitiesCard(pendingCount:2)))));
      await settleReads(t);
      final row=t.widget<SyncStripRow>(find.byType(SyncStripRow));
      expect(row.window.label,'On your band');expect(row.window.missing,21600);
      expect(repo.days.toSet(),{'2026-11-18','2026-11-19'});
      expect(row.pending.map((s)=>s.id),['nap','walk']);
      expect(row.description,'A nap and a walk to review');
      state.setThrough(now);await settleReads(t);
      expect(t.widget<SyncStripRow>(find.byType(SyncStripRow)).window.realSeconds,7200);
      await t.runAsync(()=>PilotFlags.set(PilotFlag.syncStrip,false));await t.pump();
      expect(find.byType(SyncStripRow),findsNothing);expect(find.byType(ActionCard),findsOneWidget);
      expect(t.takeException(),isNull);
      await t.pumpWidget(const SizedBox());state.dispose();
    });
  });
  // why: read failures must retain the existing retry text rather than an empty state.
  // catches: swallowing a failed day read and claiming a successful breakdown.
  testWidgets('failed day read keeps failure text', (t)async{
    await withClock(Clock.fixed(now),()async{
      final repo=_Repo()..fail=true;
      final app=_App(repo);
      bool? review;
      await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value:app,child:MaterialApp(theme:buildTheme(Brightness.dark),home:Scaffold(body:SyncStripHome(count:0,onOpen:(value)=>review=value)))));
      await settleReads(t);
      expect(find.text('Could not load activities. Try again.'),findsOneWidget);
      await t.tap(find.text('Review'));expect(review,true);
      await t.pumpWidget(const SizedBox());app.dispose();
    });
  });
}
