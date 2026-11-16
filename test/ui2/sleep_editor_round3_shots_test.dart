// Actual dark Flutter captures of the owner's v3 flows, with layout failures fatal.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../support/bundled_fonts.dart';
import '../support/day_timeline_fixtures.dart';
import 'sleep_editor_review_r1_test.dart' as rig;
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/control_operations.dart';
class _Never implements SleepEditSaver {
 @override
 ({Future<void> written,Future<SleepOperationResult> done}) save(SleepEditPlan plan)=>throw StateError('Capture cannot write');
}
class _Editor implements DayRowEditListener {
 @override
 dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
void main(){
 testWidgets('dark v3 default, add steps, ghost confirm, removed outline and undo',(t)async{
  t.view.physicalSize=const Size(412,850);t.view.devicePixelRatio=1;addTearDown(t.view.reset);
  await t.runAsync(loadFonts);
  const key=ValueKey('v3-shot');
  Future<void> shot(String name)async{
   expect(t.takeException(),isNull);
   final boundary=t.renderObject<RenderRepaintBoundary>(find.byKey(key));
   await t.runAsync(()async{
    final img=await boundary.toImage(pixelRatio:2);
    final bytes=await img.toByteData(format:ui.ImageByteFormat.png);
    final dir=Directory('build/editor-round3-shots')..createSync(recursive:true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());img.dispose();
   });
  }
  final d=dtNight(withNap:false);
  await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(debugShowCheckedModeBanner:false,
   theme:buildTheme(Brightness.dark),home:SleepTimelineEditor(data:d,save:_Never()))));
  await t.pumpAndSettle();
  final s=t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
  await shot('default');
  await t.tap(find.byKey(SleepTimelineEditor.addKey));await t.pumpAndSettle();await shot('add-start');
  await rig.tapTime(t,s,dtAt(800));await shot('add-end');
  await rig.tapTime(t,s,dtAt(840));
  expect(s.blocks,hasLength(2));await shot('added-nap');
  await t.tap(find.byKey(const ValueKey('sleep-editor-remove')));await t.pumpAndSettle();await shot('remove-undo');
  await t.tap(find.byType(SnackBarAction));await t.pumpAndSettle();
  s.blockSelected('main',zoom:false);
  s.blocksChanged([d.main.copyWith(start:d.main.start+1800,end:d.main.end+900),s.blocks.last]);
  s.controller.reset();await t.pumpAndSettle();
  await t.tap(find.byKey(ChartAnnotationLane.iconKey('ghost:main:start')));
  await t.pump(const Duration(milliseconds:350));await t.pumpAndSettle();
  expect(find.byType(AlertDialog),findsOneWidget);await shot('ghost-confirm');
  await t.tap(find.byKey(const ValueKey('sleep-editor-ghost-confirm')));await t.pumpAndSettle();await shot('reset-undo');

  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(
    RepaintBoundary(key:key,
      child:MaterialApp(debugShowCheckedModeBanner:false,theme:buildTheme(Brightness.dark),
        home:Scaffold(body:SafeArea(child:Padding(padding:const EdgeInsets.all(12),
          child:ActivitiesTimeline(
            data:TimelineData(day:d.day,graph:DayGraph(dayStart:d.domainStart,hr:d.hr,movement:d.movement)),
            rows:[
              (id:'saved:walk',moment:Moment(at:dtAt(780),title:'Walk',icon:LucideIcons.footprints,annotationKind:AnnotationKind.workout)),
              (id:'saved:nap',moment:Moment(at:dtAt(1050),until:dtAt(1090),title:'Nap',icon:LucideIcons.bedDouble,annotationKind:AnnotationKind.nap)),
            ],review:null,editor:_Editor(),
          ),
        ))),
      ),
    ),
  );
  await t.pumpAndSettle();await shot('day-filter-button');
  await t.tap(find.byKey(ActivitiesTimeline.filterButtonKey));await t.pumpAndSettle();await shot('day-filter-sheet');
 },skip:Platform.environment['EDITOR_FIXES_SHOTS']!='1');
}
