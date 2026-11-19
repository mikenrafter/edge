import 'dart:io';
import 'dart:ui' as ui;
import 'package:clock/clock.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import '../support/header_rows_fakes.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/sync_strip.dart';
import 'package:openstrap_edge/pilot/sync_strip_overlay.dart';
import 'package:openstrap_edge/ui2/day_timeline/day_graph.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_controller.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/state/prefs.dart';

const _boundary=ValueKey('capture');
const _window=SyncStripWindow(now:100000,last:94300,connected:true,reportedNewest:99000);
Future<void> mount(WidgetTester t,Widget child,{double scale=1,double width=390})async{
  t.view.resetPhysicalSize();
  t.view.physicalSize=Size(width,520);t.view.devicePixelRatio=1;
  await t.pumpWidget(RepaintBoundary(key:_boundary,child:MaterialApp(debugShowCheckedModeBanner:false,theme:buildTheme(Brightness.dark),home:MediaQuery(data:MediaQueryData(size:Size(width,520),textScaler:TextScaler.linear(scale)),child:Scaffold(body:Padding(padding:const EdgeInsets.all(16),child:child))))));
  await t.pump();
}
Future<void> capture(WidgetTester t,String name)async{
  if(!const bool.fromEnvironment('SYNC_STRIP_SHOTS'))return;
  final boundary=t.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
  await t.runAsync(()async{
    final image=await boundary.toImage(pixelRatio:2);
    final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
    await Directory('/tmp/sync-strip-shots').create(recursive:true);
    await File('/tmp/sync-strip-shots/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
void main(){
  setUpAll(()async{
    final material=FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await material.load();
    for(final family in ['Manrope','.SF Pro Text']){
      final fonts=FontLoader(family);
      for(final weight in [400,500,600,700,800]){fonts.addFont(rootBundle.load('assets/fonts/Manrope/Manrope-$weight.ttf'));}
      await fonts.load();
    }
  });
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();});

  // why: m334's signed-off caption uses kinds only if the actual text fits.
  // catches: always showing a count, or leaving the kinds caption ellipsized.
  testWidgets('caption uses kinds at room and count at large text', (t)async{
    const text='A nap, a walk and a moment to review';
    await mount(t,SyncStripRow(window:_window,count:3,description:text,onOpen:(){}),width:700);
    expect(find.text(text),findsOneWidget);expect(find.text('3 items to review'),findsNothing);
    await mount(t,SyncStripRow(window:_window,count:3,description:text,onOpen:(){}),scale:1.3);
    expect(find.text('3 items to review'),findsOneWidget);expect(find.text(text),findsNothing);
    expect(t.takeException(),isNull);await capture(t,'caption-scale-1.3');
    await t.pumpWidget(const SizedBox());
  });
  // why: m336 requires a readable band label at each supported text scale.
  // catches: painting the label into the default third and clipping its text.
  for(final scale in [1.0,1.3,2.0]) {
    for(final connected in [false,true]) {
    testWidgets('320 dp band label fits at scale $scale connected=$connected', (t)async{
      await mount(t,SyncStripRow(window:SyncStripWindow(now:100000,last:78400,connected:connected,reportedNewest:99900),count:0,onOpen:(){}),scale:scale,width:320);
      final label=find.byKey(const ValueKey('sync-strip-band-label'));
      expect(label,findsOneWidget);
      final text=t.widget<Text>(label);
      expect(text.style!.fontSize,F.cap.fontSize);
      expect(['Maybe on your band','Maybe on band','?','On your band','On band'],contains(text.data));
      final plotWidth=t.getSize(find.byType(SyncStripPlot)).width;
      final full=connected?'On your band':'Maybe on your band';
      final fullMeasure=TextPainter(text:TextSpan(text:full,style:text.style),textDirection:TextDirection.ltr,textScaler:TextScaler.linear(scale))..layout();
      if(fullMeasure.width.ceilToDouble()+12<=plotWidth){expect(text.data,full);}
      fullMeasure.dispose();
      expect(text.overflow,isNot(TextOverflow.ellipsis));
      expect(t.renderObject<RenderParagraph>(label).didExceedMaxLines,false);
      final measure=TextPainter(text:TextSpan(text:text.data,style:text.style),textDirection:TextDirection.ltr,textScaler:TextScaler.linear(scale))..layout();
      expect(measure.width,lessThanOrEqualTo(t.getSize(label).width+.01));measure.dispose();
      expect(t.takeException(),isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
  }
  // why: the opt-in must preserve today's review card until explicitly enabled.
  // catches: replacing the card unconditionally or enabling the pilot by default.
  testWidgets('flag off keeps both original ActionCard states', (t)async{
    expect(PilotFlag.syncStrip.enabled,false);
    await mount(t,const DetectedActivitiesCard(pendingCount:3));
    expect(find.byType(ActionCard),findsOneWidget);expect(find.text('3 to review'),findsOneWidget);expect(find.byType(SyncStripHome),findsNothing);
    await t.pumpWidget(const SizedBox());
    await mount(t,const DetectedActivitiesCard(pendingCount:0));
    expect(find.text('Breakdown of your day'),findsOneWidget);expect(find.text('Open'),findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  // why: help must be a Material sheet and the CTA must carry no count.
  // catches: inline help expansion, a missing key, or a count inside Review.
  testWidgets('inline row opens themed help and keeps one action', (t)async{
    var opens=0;
    final graph=DayGraph(dayStart:82900,hr:List.generate(190,(i)=>i%15==0?null:65+(i%30).toDouble()),rest:const [(0,70,C.blue)],work:const [(90,120,C.orange)]);
    await mount(t,SyncStripRow(window:_window,count:3,description:'A nap, a walk and a moment to review',graphs:[graph],pending:const [ActivitySuggestion(id:'nap',kind:ActivityKind.nap,startTs:83500,endTs:85000,revision:1),ActivitySuggestion(id:'walk',kind:ActivityKind.workout,startTs:88500,endTs:90300,revision:1)],moments:const [93000],onOpen:()=>opens++));
    expect(find.text('Review'),findsOneWidget);expect(find.text('3'),findsNothing);
    await t.tap(find.text('Review'));expect(opens,1);await capture(t,'review-syncing');
    await t.tap(find.byTooltip('What is the faded part?'));await t.pumpAndSettle();
    expect(find.byType(BottomSheet),findsOneWidget);
    expect(find.text('Heart rate the phone has'),findsOneWidget);
    expect(find.text('Not synced yet'),findsOneWidget);expect(find.text('Waiting for review'),findsOneWidget);
    expect(find.textContaining('still on your band'),findsOneWidget);await capture(t,'bottom-sheet');
    await t.tap(find.text('Got it'));await t.pumpAndSettle();
    await mount(t,SyncStripRow(window:const SyncStripWindow(now:100000,last:78400),count:0,graphs:[DayGraph(dayStart:35200,hr:List.generate(720,(i)=>65+(i%30).toDouble()),rest:const [(0,300,C.blue)],work:const [(550,590,C.orange)])],onOpen:(){}));
    expect(find.text('View day'),findsOneWidget);await capture(t,'nothing-band-away');
    await t.pumpWidget(const SizedBox());
  });
  // why: original and pilot charts share the same fade and band-time wording.
  // catches: treating backlog as an ETA, or drawing an overlay while switched off.
  testWidgets('timeline overlay is off by default and uses band time when on', (t)async{
    const overlay= SizedBox(height:180,child:Stack(children:[Positioned.fill(child:SyncStripOverlay(view:TimelineView(82000,102000),window:_window))]));
    await mount(t,overlay);expect(find.byWidgetPredicate((w)=>w is CustomPaint&&w.painter is SyncStripOverlayPainter),findsNothing);
    await t.runAsync(()=>PilotFlags.set(PilotFlag.syncStrip,true));await t.pump();
    expect(find.byWidgetPredicate((w)=>w is CustomPaint&&w.painter is SyncStripOverlayPainter),findsOneWidget);
    final semantics=t.ensureSemantics();await t.pump();
    expect(find.bySemanticsLabel('On your band. 1 h 19 m still on your band'),findsOneWidget);
    await capture(t,'timeline-unsynced');semantics.dispose();
    await t.pumpWidget(const SizedBox());
  });
  // why: the two shipped chart paths must both show the overlay, using their existing axes.
  // catches: wiring only the isolated overlay or only one of the chart variants.
  testWidgets('original and Labs chart both inherit the sync overlay', (t)async{
    await t.runAsync(()=>PilotFlags.set(PilotFlag.syncStrip,true));
    final app=HeaderApp(through:DateTime.fromMillisecondsSinceEpoch(94300*1000));
    app.device.dataRangeNewest=99000;
    final graph=DayGraph(dayStart:82000,hr:List.generate(300,(i)=>65.0+(i%30)));
    final controller=TimelineController(homeStartSec:82000,homeEndSec:100000);
    final interaction=TimelineInteraction();
    await withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(100000*1000)),()async{
      for(final pilot in [false,true]){
        final chart=pilot?PilotTimelineChart(controller:controller,graph:graph,interaction:interaction,syncStrip:true)
          :SharedTimelineChart(controller:controller,graph:graph,syncStrip:true,onAnnotationSelected:(_){});
        await mount(t,ChangeNotifierProvider<AppState>.value(value:app,child:chart));
        expect(find.byWidgetPredicate((w)=>w is CustomPaint&&w.painter is SyncStripOverlayPainter),findsOneWidget);
        if(pilot){
          final overlay=t.widget<CustomPaint>(find.byWidgetPredicate((w)=>w is CustomPaint&&w.painter is SyncStripOverlayPainter));
          expect(overlay.foregroundPainter,isA<PilotTimelineAxesPainter>());
        }
        if(!pilot){
          expect(find.text('90 bpm'),findsOneWidget);
          controller.setScrub(99940);await t.pump();
          expect(find.text('94 bpm'),findsNothing);controller.clearScrub();await t.pump();
        }
        await capture(t,pilot?'timeline-pilot':'timeline-original');
        await t.pumpWidget(const SizedBox());
      }
    });
    controller.dispose();interaction.dispose();app.dispose();
  });

  // why: a stale cached curve must not remain visible beyond the durable frontier.
  // catches: removing the opaque mask and only tinting the cached measurements.
  test('overlay erases cached measurements after the last synced record', ()async{
    final recorder=ui.PictureRecorder();
    final drawing=Canvas(recorder);
    drawing.drawRect(const Rect.fromLTWH(0,0,300,120),Paint()..color=const Color(0xFFFF0000));
    SyncStripOverlayPainter(p:P(true),view:const TimelineView(0,300),window:const SyncStripWindow(now:250,last:100)).paint(drawing,const Size(300,120));
    final picture=recorder.endRecording();
    final image=await picture.toImage(300,120);
    final bytes=(await image.toByteData(format:ui.ImageByteFormat.rawRgba))!;
    List<int> pixel(int x,int y)=>List.generate(4,(channel)=>bytes.getUint8((y*300+x)*4+channel));
    expect(pixel(30,70),[255,0,0,255]);
    expect(pixel(180,70),isNot([255,0,0,255]));
    expect(pixel(280,70),isNot([255,0,0,255]));
    image.dispose();picture.dispose();
  });

  // why: m334 keeps the review and breakdown slot the same shape.
  // catches: the longer View day action adding height only in the empty state.
  testWidgets('row height stays fixed when the review state changes', (t)async{
    for(final scale in [1.0,1.3,2.0,3.0]){
      await mount(t,SyncStripRow(window:_window,count:0,onOpen:(){}),width:320,scale:scale);
      final height=t.getSize(find.byType(SyncStripRow)).height;
      await mount(t,SyncStripRow(window:_window,count:3,onOpen:(){}),width:320,scale:scale);
      expect(t.getSize(find.byType(SyncStripRow)).height,height);
      expect(t.takeException(),isNull);
    }
    await t.pumpWidget(const SizedBox());
  });

  // why: pending ranges and timed review points share the strip's baseline key.
  // catches: omitting non-proposal review marks or putting them in the unsynced area.
  test('pending range and review point are underlined only at their times', ()async{
    final recorder=ui.PictureRecorder(),palette=P(true);
    SyncStripPainter(p:palette,window:const SyncStripWindow(now:100000,last:100000),reviewRanges:const [(94000,97000)],moments:const [98500]).paint(Canvas(recorder),const Size(240,44));
    final picture=recorder.endRecording();
    final image=await picture.toImage(240,44);
    final bytes=(await image.toByteData(format:ui.ImageByteFormat.rawRgba))!;
    int pixel(int x)=>bytes.getUint8((29*240+x)*4+3);
    expect(pixel(50),255);expect(pixel(190),255);expect(pixel(20),0);expect(pixel(220),0);
    image.dispose();picture.dispose();
  });

  // why: fidelity item 2 must distinguish an empty fixture from connection gating.
  // catches: hiding phone-held HR when the band disconnects.
  test('disconnect preserves the real HR pixels before the faded band', ()async{
    final graph=DayGraph(dayStart:35200,hr:List.generate(720,(i)=>65+(i%30).toDouble()));
    Future<List<int>> render(bool connected)async{
      final recorder=ui.PictureRecorder();
      SyncStripPainter(p:P(true),window:SyncStripWindow(now:100000,last:78400,connected:connected,reportedNewest:99000),graphs:[graph],realWidth:160).paint(Canvas(recorder),const Size(240,44));
      final picture=recorder.endRecording();
      final image=await picture.toImage(240,44);
      final bytes=(await image.toByteData(format:ui.ImageByteFormat.rawRgba))!;
      final region=<int>[];
      for(var y=0;y<31;y++){for(var x=0;x<120;x++){for(var channel=0;channel<4;channel++){region.add(bytes.getUint8((y*240+x)*4+channel));}}}
      image.dispose();picture.dispose();return region;
    }
    final connected=await render(true),away=await render(false);
    expect(away,connected);
    var red=0;
    for(var i=0;i<away.length;i+=4){if(away[i]>away[i+1]*1.5&&away[i]>away[i+2]*1.5&&away[i+3]>0)red++;}
    expect(red,greaterThan(20));
  });

  // why: fidelity item 1 requires centring inside the band, not a floating label over HR.
  // catches: left-edge placement, ellipsis, shrinking text, or overlap with the axis/now.
  test('timeline label uses full short and symbol text while staying centred', (){
    for(final band in [const Rect.fromLTWH(50,30,300,160),const Rect.fromLTWH(200,30,120,160),const Rect.fromLTWH(290,30,30,160),const Rect.fromLTWH(316,30,4,160)]){
      final layout=syncBandLabelLayout(window:_window,band:band,plotLeft:0,axisLeft:band.right,style:F.cap,scaler:TextScaler.noScaling);
      expect(layout.bounds.center,band.center);
      expect(layout.bounds.left,greaterThanOrEqualTo(band.left));expect(layout.bounds.right,lessThanOrEqualTo(band.right));
      expect(layout.bounds.overlaps(layout.nowBounds),false);
      expect(layout.nowBounds.bottom,lessThan(band.top));
      if(band.width==300){expect(layout.text,'On your band\n1 h 19 m still on your band');}
      if(band.width==120){expect(layout.text,'On band\n1 h 19 m');}
      if(band.width==30){expect(layout.text,'?');}
      if(band.width==4){expect(layout.text,'');}
    }
    final axisCase=syncBandLabelLayout(window:_window,band:const Rect.fromLTWH(200,20,120,92),plotLeft:0,axisLeft:296,style:F.cap,scaler:TextScaler.linear(2));
    expect(axisCase.bounds.right,lessThanOrEqualTo(290));expect(axisCase.nowBounds.right,lessThanOrEqualTo(290));
    expect(axisCase.bounds.center,const Offset(260,66));
    expect(axisCase.bounds.overlaps(axisCase.nowBounds),false);
  });

}
