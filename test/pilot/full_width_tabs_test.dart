// why: owner m249 — SubTabs share the row equally (Labs "Full-width tabs",
// default on) and fall back to the scrolling pills when a tab won't fit.
// catches: unequal shares, squeezing long tabs instead of scrolling, or the
// flag-off path changing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show SubTabs;
import 'screens_test.dart' show pump;

void main(){
  setUp(()async{SharedPreferences.setMockInitialValues({});await Prefs.reload();});
  Future<void> tabs(WidgetTester t,List<String> items)=>pump(t,Scaffold(body:Padding(padding:const EdgeInsets.all(16),child:SubTabs(items,0,(_){},itemKeys:[for(var i=0;i<items.length;i++)ValueKey('t$i')]))));
  testWidgets('three short tabs fill the width equally',(t)async{
    expect(PilotFlag.fullWidthTabs.enabled,true);
    await tabs(t,['Day','Week','Month']);
    expect(find.descendant(of:find.byType(SubTabs),matching:find.byType(SingleChildScrollView)),findsNothing);
    final w=[for(var i=0;i<3;i++)t.getSize(find.byKey(ValueKey('t$i'))).width];
    expect(w[0],moreOrLessEquals(w[1],epsilon:.5));expect(w[1],moreOrLessEquals(w[2],epsilon:.5));
    expect(w.reduce((a,b)=>a+b),greaterThan(358-3*8));
  });
  testWidgets('six long tabs scroll at their minimum width',(t)async{
    await tabs(t,[for(var i=0;i<6;i++)'Long tab label $i']);
    expect(find.descendant(of:find.byType(SubTabs),matching:find.byType(SingleChildScrollView)),findsOneWidget);
  });
  testWidgets('flag off keeps the scrolling pills',(t)async{
    await PilotFlags.set(PilotFlag.fullWidthTabs,false);
    await tabs(t,['Day','Week','Month']);
    expect(find.descendant(of:find.byType(SubTabs),matching:find.byType(SingleChildScrollView)),findsOneWidget);
  });
}
