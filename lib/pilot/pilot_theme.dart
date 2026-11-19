import 'package:flutter/material.dart';
import '../ui2/theme.dart';

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
