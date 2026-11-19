// Owner: PilotWakeLight owns foreground light pulses and their torch cleanup.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../platform/device_actions.dart';
import 'pilot_flags.dart';
import 'wake_runtime.dart';

class PilotSunriseOverlay extends StatelessWidget {
  const PilotSunriseOverlay({super.key,required this.child});
  final Widget child;
  @override Widget build(BuildContext context)=>ValueListenableBuilder<int>(valueListenable:PilotFlags.revision,builder:(context,_,_){
    if(!PilotFlag.alarmScreen.enabled||!PilotFlag.wakeMethods.enabled)return child;
    return PilotWakeLight(runtime:context.read<AppState>().pilotWake,child:child);
  });
}
class PilotWakeLight extends StatefulWidget {
  const PilotWakeLight({super.key,required this.runtime,required this.child,this.torch=DeviceActions.setTorch});
  final PilotWakeRuntime runtime;final Widget child;
  final Future<bool> Function(bool) torch;
  @override State<PilotWakeLight> createState()=>_WakeLightState();
}
class _WakeLightState extends State<PilotWakeLight> with SingleTickerProviderStateMixin,WidgetsBindingObserver {
  late final AnimationController animation=AnimationController(vsync:this,duration:const Duration(milliseconds:700));
  Timer? _pulse;bool _bright=false,_foreground=true,_torchOwned=false,_torchUnavailable=false;
  Future<void> _torchTail=Future.value();
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);widget.runtime.effects.addListener(_sync);widget.runtime.flash.addListener(_sync);_sync();}
  bool get ramping{final at=widget.runtime.firedAt;return !widget.runtime.acknowledged&&widget.runtime.firedAlarm?.sunrise==true&&at!=null&&DateTime.now().difference(at)<=widget.runtime.leadUps.finishDuration;}
  void _torch(bool enabled){
    _torchTail=_torchTail.then((_)async{
      if(enabled&&_torchUnavailable)return;
      if(!enabled&&!_torchOwned)return;
      bool ok;try{ok=await widget.torch(enabled);}catch(_){ok=false;}
      if(ok)_torchOwned=enabled;else if(enabled)_torchUnavailable=true;
    });
  }
  void _sync(){
    if(_foreground&&ramping){if(!animation.isAnimating)animation.repeat();}else animation.stop();
    if(_foreground&&widget.runtime.flash.value){
      if(_pulse==null){_torchUnavailable=false;_bright=true;_torch(true);_pulse=Timer.periodic(const Duration(milliseconds:700),(_){if(mounted){setState(()=>_bright=!_bright);_torch(_bright);}});}
    }else{_pulse?.cancel();_pulse=null;_bright=false;_torch(false);}
    if(mounted)setState((){});
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state){_foreground=state==AppLifecycleState.resumed;_sync();}
  @override void dispose(){WidgetsBinding.instance.removeObserver(this);widget.runtime.effects.removeListener(_sync);widget.runtime.flash.removeListener(_sync);_pulse?.cancel();_torch(false);animation.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:animation,child:widget.child,builder:(context,child){
    final light=_foreground?widget.runtime.lightAt(DateTime.now()):0.0;
    return Stack(children:[child!,if(light>0)Positioned.fill(child:IgnorePointer(child:ColoredBox(color:Color.lerp(Colors.transparent,const Color(0xffffd8a0),light*.9)!))),
      if(_bright)const Positioned.fill(child:IgnorePointer(child:ColoredBox(key:ValueKey('pilot-screen-flash'),color:Colors.white))),
    ]);
  });
}
