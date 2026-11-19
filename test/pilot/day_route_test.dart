import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import '../support/apk2_review_harness.dart';

void main(){
  // why: m195 requires programmatic list reveal during a real hand scrub to be inert.
  // catches: snapping the chart to a row time when the scrub reveals that row.
  testWidgets('hand scrub reveals highlighted row without moving chart view or cursor',(t)async{
    final rig=await Apk2Rig.create(t);await PilotFlags.set(PilotFlag.timelines,true);await rig.mount(t,size:const Size(390,844));
    final chart=t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    final view=chart.controller.view,plot=t.getRect(find.byKey(const ValueKey('pilot-timeline-plot')));
    final page=t.widget<SingleChildScrollView>(find.byKey(const ValueKey('pilot-day-list')));
    expect(page.controller!.offset,0);
    final gesture=await t.startGesture(Offset(plot.left+plot.width*.78,plot.center.dy));await t.pump(const Duration(milliseconds:350));
    final cursor=chart.controller.scrub;expect(chart.interaction.handScrubbing,true);
    expect(cursor,apk2At(18,45).toDouble()); // .78 of 24h = 18:43; 5-min snap = 18:45.
    await t.pump(const Duration(milliseconds:900));
    expect(page.controller!.offset,greaterThan(0));expect(chart.controller.view,view);expect(chart.controller.scrub,cursor);expect(chart.interaction.autoPinned,true);
    await gesture.up();await t.pumpAndSettle();expect(chart.controller.scrub,cursor);expect(t.takeException(),null);
  });
  // why: m192 keeps Keep/Discard/Edit in one row even at large text scales.
  // catches: vertically stacking actions or overflowing the row's right edge.
  testWidgets('pending nap and workout retain three actions inside each row at large text',(t)async{
    final rig=await Apk2Rig.create(t);await PilotFlags.set(PilotFlag.timelines,true);await rig.mount(t,scale:2,size:const Size(390,1000));
    for(final id in [apk2NapA,apk2WorkoutA]){
      final row=apk2Row(id);await t.ensureVisible(row);await t.pumpAndSettle();
      final bounds=t.getRect(row),keep=t.getRect(apk2Keep(id)),discard=t.getRect(apk2Discard(id)),edit=t.getRect(find.byKey(ValueKey('day-review-label:$id')));
      expect(keep.center.dy,discard.center.dy);expect(discard.center.dy,edit.center.dy);
      expect(keep.left,greaterThanOrEqualTo(bounds.left));expect(edit.right,lessThanOrEqualTo(bounds.right));
      // m192: labels never wrap ("Discar / d" in the first fidelity shots).
      expect(t.widget<Text>(find.descendant(of:apk2Discard(id),matching:find.text('Discard'))).maxLines,1);
    }
    expect(t.takeException(),null);
  });
  // why: Restore is staged with Save and refuses stale revisions or a disabled pilot.
  // catches: direct status writes on tapping Restore or unguarded restoration.
  testWidgets('discarded activity restores atomically through the existing day-save seam',(t)async{
    final rig=await Apk2Rig.create(t);await PilotFlags.set(PilotFlag.timelines,false);await t.runAsync(()async{final id=apk2WorkoutA.substring(9),before=(await rig.store.get(id))!;
    await rig.store.discard(before);final discarded=(await rig.store.get(id))!;
    expect(discarded.status,ActivityReviewStatus.discarded);
    final repo=LocalRepositoryImpl(getProfileMap:()=>{});
    Future<void> restore()=>repo.saveDayReview(activities:[ActivityDecision(discarded,keep:true,restore:true)],moments:const []);
    await expectLater(restore(),throwsA(isA<ActivityReviewException>()));expect((await rig.store.get(id))!.status,ActivityReviewStatus.discarded);
    await PilotFlags.set(PilotFlag.timelines,true);await restore();
    final restored=(await rig.store.get(id))!;expect(restored.status,ActivityReviewStatus.pending);expect(restored.revision,discarded.revision+1);
    await expectLater(restore(),throwsA(isA<ActivityReviewException>()));expect((await rig.store.get(id))!.revision,restored.revision);
    });
  });
}
