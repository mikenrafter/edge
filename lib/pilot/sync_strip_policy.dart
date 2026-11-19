// Owner: immutable sync-strip presentation, derived only from observed times.
import '../sync/sync_policy.dart' show isCorruptFutureRtc;

class SyncStripWindow {
  const SyncStripWindow({required this.now,required this.last,this.reportedNewest,this.connected=false});
  final int now;
  final int? last,reportedNewest;
  final bool connected;
  bool get _hasRange => connected && last!=null && reportedNewest!=null &&
    reportedNewest!>=last! && !isCorruptFutureRtc(reportedNewest!,now);
  bool get reported => _hasRange && reportedNewest!>last!;
  int get missing {
    final edge=last;
    if(edge==null||edge>=now)return 0;
    if(_hasRange && reportedNewest!<=edge+60 && now-edge<=300)return 0;
    return now-edge;
  }
  bool get compressed => missing>8*3600;
  int get realSeconds => missing==0?7200:compressed?16*3600:missing*2;
  int get start => (last??now)-realSeconds;
  double get realFraction => missing==0?1:2/3;
  String get label => reported?'On your band':'Maybe on your band';
  String get statusLabel => last==null?'No synced records yet':missing>0?label:'All synced';
  String get backlogLabel {
    if(!reported)return 'Not synced for ${bandDuration(missing)}';
    final seconds=reportedNewest!-last!;
    return seconds>0?'${bandDuration(seconds)} still on your band':'No newer records reported';
  }
}
String bandDuration(int seconds){
  final minutes=(seconds/60).ceil();
  if(minutes<60)return '$minutes min';
  final hours=minutes~/60,rest=minutes%60;
  return rest==0?'$hours h':'$hours h $rest m';
}
