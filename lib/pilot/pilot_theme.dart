import 'package:flutter/material.dart';
import '../ui2/theme.dart';
import '../ui2/grammar.dart' show Pressable;

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
/// targets. Drawn at 32 px so it never sets a timing row's height; Pressable
/// keeps the 44 pt hit box.
class PilotRowChip extends StatelessWidget {
  const PilotRowChip(this.label,{super.key,required this.onTap});
  final String label;final VoidCallback onTap;
  @override Widget build(BuildContext context){final p=P.of(context);
    return Pressable(onTap:onTap,semanticLabel:label,child:Container(height:32,padding:const EdgeInsets.symmetric(horizontal:10),alignment:Alignment.center,
      decoration:BoxDecoration(color:p.card2,borderRadius:BorderRadius.circular(9)),
      child:Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink,fontSize:12))));}
}
