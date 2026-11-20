import 'package:flutter/material.dart';
import '../ui2/theme.dart';
import '../ui2/scroll_quiet.dart' show QuietTap;
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

/// Mock-ups' timing row (alarms v22 / sleep editor v11 `.item`): a coloured
/// glyph (no tile), the name, an optional in-row action right after it, and
/// the time on the right with its subtitle under it (11 px #9aa6b8). Selected:
/// #232c3d with a 1 px #4a5f92 border, radius 12. Min height 48.
class PilotItemRow extends StatelessWidget {
  const PilotItemRow({super.key,required this.icon,required this.color,required this.title,required this.time,
    this.timeSub,this.titleSub,this.action,this.selected=false,this.glow,this.timeColor,this.onTap});
  final IconData icon;final Color color;final String title,time;final String? timeSub,titleSub;
  final Widget? action;final bool selected;final Color? glow,timeColor;final VoidCallback? onTap;
  @override Widget build(BuildContext context){final p=P.of(context);
    return LayoutBuilder(builder:(context,box)=>Semantics(button:onTap!=null,selected:selected,child:QuietTap(behavior:HitTestBehavior.opaque,onTap:onTap,child:Container(
      constraints:const BoxConstraints(minHeight:48),margin:const EdgeInsets.symmetric(vertical:1),padding:const EdgeInsets.symmetric(horizontal:10,vertical:8),
      decoration:BoxDecoration(color:glow??(selected?const Color(0xFF232C3D):null),borderRadius:BorderRadius.circular(12),border:Border.all(color:selected?const Color(0xFF4A5F92):Colors.transparent)),
      child:Row(children:[
        Icon(icon,size:18,color:p.on(color)),const SizedBox(width:10),
        Expanded(child:Row(children:[
          Flexible(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[
            Text(title,maxLines:1,overflow:TextOverflow.ellipsis,style:F.body.copyWith(color:p.ink)),
            if(titleSub!=null)Text(titleSub!,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:const Color(0xFF9AA6B8),fontSize:11)),
          ])),
          if(action!=null)...[const SizedBox(width:10),action!],
        ])),
        const SizedBox(width:10),
        ConstrainedBox(constraints:BoxConstraints(maxWidth:box.maxWidth*.45),child:Column(crossAxisAlignment:CrossAxisAlignment.end,mainAxisSize:MainAxisSize.min,children:[
          Text(time,maxLines:1,style:F.body.copyWith(color:timeColor??p.ink,fontFeatures:const [FontFeature.tabularFigures()])),
          Text(timeSub??'',maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.right,style:F.cap.copyWith(color:const Color(0xFF9AA6B8),fontSize:11)),
        ])),
      ])))));}
}
