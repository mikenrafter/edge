import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import 'pilot_flags.dart';
import 'wake_runtime.dart';

class PilotSunriseOverlay extends StatelessWidget {
  const PilotSunriseOverlay({super.key,required this.child});
  final Widget child;
  @override Widget build(BuildContext context)=>ValueListenableBuilder<int>(valueListenable:PilotFlags.revision,builder:(context,_,_){
    if(!PilotFlag.alarmScreen.enabled||!PilotFlag.wakeMethods.enabled)return child;
    return _WakeLight(runtime:context.read<AppState>().pilotWake,child:child);
  });
}
class _WakeLight extends StatefulWidget {
  const _WakeLight({required this.runtime,required this.child});
  final PilotWakeRuntime runtime;final Widget child;
  @override State<_WakeLight> createState()=>_WakeLightState();
}
class _WakeLightState extends State<_WakeLight> with SingleTickerProviderStateMixin {
  late final AnimationController animation=AnimationController(vsync:this,duration:const Duration(milliseconds:700));
  @override void initState(){super.initState();widget.runtime.effects.addListener(_sync);_sync();}
  bool get ramping{final at=widget.runtime.firedAt;return !widget.runtime.acknowledged&&widget.runtime.firedAlarm?.sunrise==true&&at!=null&&DateTime.now().difference(at)<=widget.runtime.leadUps.finishDuration;}
  void _sync(){if(ramping){if(!animation.isAnimating)animation.repeat();}else animation.stop();if(mounted)setState((){});}
  @override void dispose(){widget.runtime.effects.removeListener(_sync);animation.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:animation,child:widget.child,builder:(context,child){
    final light=widget.runtime.lightAt(DateTime.now());
    return Stack(children:[child!,if(light>0)Positioned.fill(child:IgnorePointer(child:ColoredBox(color:Color.lerp(Colors.transparent,const Color(0xffffd8a0),light*.9)!)))]);
  });
}
