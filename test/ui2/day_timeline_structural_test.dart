import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_filter.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/apk2_review_harness.dart';
import '../support/pin_tz.dart';

// WHY: spec §4.4 has one filter/identity policy for chart and rows.
// CLAIM(timeline-row-identity). Catches: timestamp or occurrence-index reveal.
void main() {
  pinProcessTimeZone('America/Denver');
  testWidgets('D1 zoom and text-only Filter occupy scrub card corners', (t) async {
    final rig=await Apk2Rig.create(t); await rig.mount(t);
    final zoom=find.byKey(const ValueKey('timeline-zoom')), filter=find.byKey(const ValueKey('timeline-filter'));
    expect(zoom,findsOneWidget); expect(filter,findsOneWidget);
    expect(t.getRect(zoom).left,lessThan(t.getRect(filter).left));
    expect(find.descendant(of:filter,matching:find.byType(Icon)),findsNothing);
    expect(t.getSize(filter).height,greaterThanOrEqualTo(48));
  });
  test('D2 count is selected kinds; state owner refuses last-kind removal', () {
    final f=TimelineFilter(); addTearDown(f.dispose); expect(f.kinds.length,2);
    expect(f.setKinds({DayTimelineKind.discarded}),isA<TimelineFilterApplied>());
    expect(f.kinds,{DayTimelineKind.discarded});
    expect(f.setKinds({}),isA<TimelineFilterRefused>()); expect(f.kinds,{DayTimelineKind.discarded});
  });
  testWidgets('D3 one filter removes matching rows and their markers', (t) async {
    final rig=await Apk2Rig.create(t); await rig.mount(t);
    final filter=find.byKey(const ValueKey('timeline-filter')); expect(filter,findsOneWidget);
    await t.tap(filter); await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('timeline-kind:pending'))); await t.pumpAndSettle();
    await t.tapAt(const Offset(10,10)); await t.pumpAndSettle();
    expect(apk2Row(apk2WorkoutA),findsNothing);
    expect(find.byKey(const ValueKey('annotation-icon:activity:apk2-workout-a')),findsNothing);
  });
  testWidgets('D4 same-minute actual sessions reveal their exact identity', (t) async {
    final rig=await Apk2Rig.create(t,pending:false);
    rig.repo.extraTimeline={'sessions':[
      {'id':'same-a','start_ts':apk2At(9),'end_ts':apk2At(10),'type':'running'},
      {'id':'same-b','start_ts':apk2At(9),'end_ts':apk2At(10),'type':'cycling'},
    ]}; await rig.mount(t);
    for(final id in ['same-a','same-b']) {
      final marker=find.byKey(ValueKey('annotation-icon:session:$id'));
      expect(marker,findsOneWidget); await t.ensureVisible(marker); await t.tap(marker); await t.pumpAndSettle();
      final row=find.byKey(ValueKey('apk2-day-row:session:$id')); expect(row,findsOneWidget);
      expect(t.widget<Container>(row).color,isNotNull);
    }
  });
  testWidgets('D5 scrub focuses nearest row; row tap sets exact scrub', (t) async {
    final rig=await Apk2Rig.create(t,pending:false); await rig.mount(t);
    final plot=find.byKey(const ValueKey('shared-timeline-plot')); expect(plot,findsOneWidget);
    await t.dragFrom(t.getCenter(plot),const Offset(10,0)); await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-readout')),findsOneWidget);
    final row= find.byKey(const ValueKey('apk2-day-row:moment:2026-10-06 20:45'));
    expect(row,findsOneWidget); await t.ensureVisible(row); await t.tap(row); await t.pumpAndSettle();
    expect(t.widget<Container>(row).color,isNotNull);
  });
  test('D6 overlapping wake ranges retain distinct source identities', () {
    const moments=[
      Moment(at:100,until:300,title:'Gradual',icon:Icons.alarm,identity:'wake:gradual',annotationKind:AnnotationKind.wake),
      Moment(at:200,until:400,title:'Natural',icon:Icons.alarm,identity:'wake:natural',annotationKind:AnnotationKind.wake),
    ];
    final marks=dayAnnotations(moments);
    expect(marks.map((m)=>m.id),['wake:gradual','wake:natural']);
    expect(marks.map((m)=>(m.at,m.until)),[(100.0,300.0),(200.0,400.0)]);
    final reversed=dayAnnotations(moments.reversed.toList()); expect(reversed.last.id,'wake:gradual');
  });
}
