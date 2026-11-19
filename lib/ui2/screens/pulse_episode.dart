// Read-only episode metadata; publication and delivery belong to the store.
import 'package:flutter/material.dart';
import '../../compute/findings.dart';
import '../../data/pulse_ep/pulse_ep_summary.dart';
import '../../l10n/app_localizations.dart';
import '../finding_presentation.dart';
import '../ui2.dart';
import 'home_screen.dart' show prettyDay;

class PulseEpisodeRow extends StatelessWidget {
  const PulseEpisodeRow(this.episode, {super.key});
  final PulseEpisodeSummary episode;
  @override Widget build(BuildContext c) {
    final l=AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final f=Finding(FindingKind.irregularRhythm,episode.day),p=P.of(c);
    return ListTile(key:ValueKey('pulse-episode:${episode.id}'),
      leading:Icon(findingIcon(f),color:p.on(findingColor(f.kind))),
      title:Text('${prettyDay(episode.day,l)} · ${findingTitle(l,f)}',style:F.body),
      subtitle:Text('${((episode.endMs-episode.startMs)/60000).round()} min',style:F.cap),
      onTap:()=>Navigator.of(c).push(MaterialPageRoute<void>(builder:(c)=>Scaffold(
        appBar:AppBar(title:Text(findingTitle(l,f))),
        body:ListView(padding:const EdgeInsets.all(S.x4),children:[
          Text(findingDetail(l,f),style:F.body),
          const SizedBox(height:S.x4),
          Text(prettyDay(episode.day,l),style:F.cap),
          if(episode.deliveryState case final state?) Text(switch(state) { 'sent'=>'Alert sent', 'summary'=>'Alert included in a summary', 'pending'||'unknown'=>'Alert delivery unknown; it will not be repeated', 'before_version'=>'Recorded before this version', 'not_sent'=>'Alert not sent', 'held'=>'Alert held', _=>'No delivery recorded' },style:F.cap),
          const SizedBox(height:S.x4),
          Text(switch(episode.evidenceStatus) {
            'available'||'partial'=>'This build shows the episode summary. Beat review is not enabled.',
            'expired'=>'The beat recording has expired. The episode summary is retained.',
            _=>'The beat recording is unavailable. The episode summary is retained.',
          }),
        ])))));
  }
}

class PulseEpisodesScreen extends StatelessWidget {
  const PulseEpisodesScreen({super.key,required this.episodes});
  final List<PulseEpisodeSummary> episodes;
  @override Widget build(BuildContext c) => Scaffold(
    appBar:AppBar(title:const Text('Recent pulse episodes')),
    body:ListView(children:[for(final e in episodes) PulseEpisodeRow(e)]));
}
