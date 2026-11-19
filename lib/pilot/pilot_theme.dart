import 'package:flutter/material.dart';
import '../ui2/theme.dart';

class PilotTheme extends StatelessWidget {
  const PilotTheme({super.key,required this.child});
  final Widget child;
  @override Widget build(BuildContext context){
    final theme=Theme.of(context),blue=P.of(context).on(C.blue);
    return Theme(data:theme.copyWith(colorScheme:theme.colorScheme.copyWith(primary:blue),
      textButtonTheme:TextButtonThemeData(style:TextButton.styleFrom(foregroundColor:blue,minimumSize:const Size(48,48))),
      iconButtonTheme:IconButtonThemeData(style:IconButton.styleFrom(minimumSize:const Size(48,48)))),child:child);
  }
}
