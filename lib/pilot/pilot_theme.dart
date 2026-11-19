import 'package:flutter/material.dart';
import '../ui2/theme.dart';
import '../ui2/grammar.dart' show Pressable,HitOverhang;

class PilotTheme extends StatelessWidget {
  const PilotTheme({super.key,required this.child});
  final Widget child;
  @override Widget build(BuildContext context){
    final theme=Theme.of(context),blue=P.of(context).on(C.blue);
    // The app's green-seeded colour scheme stays: switches and chips must look
    // like every other switch in the app (owner m233).
    return Theme(data:theme.copyWith(
      textButtonTheme:TextButtonThemeData(style:TextButton.styleFrom(foregroundColor:blue,minimumSize:const Size(48,48))),
      iconButtonTheme:IconButtonThemeData(style:IconButton.styleFrom(minimumSize:const Size(48,48)))),child:child);
  }
}

/// The mock-ups' in-row action (.item .r: 32 px, 12 pt, card2): Reset, snap
/// targets. Laid out at 32 px so it never sets a timing row's height.
class PilotRowChip extends StatelessWidget {
  const PilotRowChip(this.label,{super.key,required this.onTap});
  final String label;final VoidCallback onTap;
  @override Widget build(BuildContext context){final p=P.of(context);
    // HitOverhang: the app's way to keep Pressable's tap height without its layout.
    return HitOverhang(visual:32,child:Pressable(onTap:onTap,semanticLabel:label,child:Container(height:32,padding:const EdgeInsets.symmetric(horizontal:10),alignment:Alignment.center,
      decoration:BoxDecoration(color:p.card2,borderRadius:BorderRadius.circular(9)),
      child:Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink,fontSize:12)))));}
}

/// The mock-ups' full-width segmented control (.tabs/.etabs: a 2 px track,
/// 40 px cells, the selected cell washed with an inset border). SubTabs scrolls
/// pills of their own width, which is not what was signed off.
class PilotSegmented extends StatelessWidget {
  const PilotSegmented(this.items,this.index,this.onTap,{super.key,this.badges=const {},this.struck=const {},this.itemKeys});
  final List<String> items;final int index;final ValueChanged<int> onTap;
  final Map<int,Widget> badges;final Set<int> struck;final List<Key?>? itemKeys;
  @override Widget build(BuildContext context){final p=P.of(context),blue=p.on(C.blue);
    return Container(padding:const EdgeInsets.all(2),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(10)),
      child:Row(children:[for(var i=0;i<items.length;i++)Expanded(child:Padding(padding:EdgeInsets.only(left:i==0?0:2),child:Semantics(selected:i==index,button:true,
        child:Pressable(key:itemKeys?[i],onTap:()=>onTap(i),semanticLabel:items[i],child:Container(height:40,alignment:Alignment.center,padding:const EdgeInsets.symmetric(horizontal:6),
          decoration:BoxDecoration(color:i==index?p.wash(C.blue):null,borderRadius:BorderRadius.circular(9),border:Border.all(color:i==index?blue.withValues(alpha:.5):Colors.transparent)),
          child:FittedBox(fit:BoxFit.scaleDown,child:Row(mainAxisSize:MainAxisSize.min,children:[
            Text(items[i],maxLines:1,style:F.cap.copyWith(fontSize:13,color:i==index?p.ink:p.ink2,decoration:struck.contains(i)?TextDecoration.lineThrough:null)),
            if(badges[i] case final b?)...[const SizedBox(width:6),b],
          ])))))))]));}
}
