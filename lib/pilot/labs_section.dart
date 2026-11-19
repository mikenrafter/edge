import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../l10n/app_localizations.dart';
import '../ui2/profile/profile.dart' show SettingsAccordion, SetRow;
import '../ui2/theme.dart';
import 'pilot_flags.dart';
import '../state/prefs.dart';

class LabsSection extends StatefulWidget {
  const LabsSection({super.key,required this.hmm,required this.onHmm,this.onAlarmSourceChanged});
  final bool hmm;final VoidCallback? onHmm;final Future<void> Function()? onAlarmSourceChanged;
  @override State<LabsSection> createState()=>_LabsState();
}
class _LabsState extends State<LabsSection>{
  String? _error;bool _saving=false;
  @override Widget build(BuildContext context){
    final l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    return SettingsAccordion(l.pilotLabs,id:'settings_labs',children:[
      for(final flag in PilotFlag.values)SwitchListTile(
        key:ValueKey(flag.key),secondary:const Icon(LucideIcons.flaskConical),
        title:Text(switch(flag){PilotFlag.sleepSummary=>'Sleep summary',PilotFlag.observations=>'Simplified observations',PilotFlag.alarmScreen=>l.pilotAlarmScreen,PilotFlag.wakeMethods=>l.pilotWakeMethods,PilotFlag.timelines=>l.pilotTimelines,PilotFlag.fullWidthTabs=>l.labsFullWidthTabs}),
        value:flag.enabled,onChanged:_saving?null:(v)async{
          setState((){_saving=true;_error=null;});
          try{await PilotFlags.set(flag,v);if(flag==PilotFlag.alarmScreen||flag==PilotFlag.wakeMethods)await widget.onAlarmSourceChanged?.call();}
          catch(e){if(mounted)setState(()=>_error=e.toString());}
          finally{if(mounted)setState(()=>_saving=false);}
        }),
      SwitchListTile(title: Text(l.personalDaySetting), value: Prefs.personalDayEnabled,
        onChanged: _saving ? null : (enabled) async {
          setState(() { _saving=true; _error=null; });
          try { if (!await Prefs.setPersonalDayEnabled(enabled)) throw StateError(l.personalDaySaveFailed); }
          catch(e) { if(mounted)setState(()=>_error=e.toString()); }
          finally { if(mounted)setState(()=>_saving=false); }
        }),
      SetRow(LucideIcons.flaskConical,C.indigo,l.experimentalSleepHmm,key:const ValueKey('experimental-sleep-hmm'),sub:l.experimentalSleepHmmDescription,value:widget.hmm?l.stateOn:l.stateOff,onTap:widget.onHmm),
      if(_error!=null)Text(_error!),
    ]);
  }
}
