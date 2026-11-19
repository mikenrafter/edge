// why: recovery/import summaries in the selected Pulse pilot must not buzz.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_alert_delivery.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../backup/backup_support.dart';
class _Probe extends PulseDeliveryProbe {
  final events=<NotificationEvent>[];
  @override Future<Set<String>?> emit(NotificationEvent e) async {events.add(e);return {'phone'};}
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env=await BackupEnv.create('pilot-pulse-recovery.db'));
  tearDownAll(()=>env.dispose());
  tearDown(()=>PulseAlertDelivery.probe=const PulseDeliveryProbe());
  for(final enabled in [false,true]) {
    // why: a daily flag has no intraday recording timestamp, so today's date
    // alone cannot authorize sound (chosen pulse-fixes policy).
    test('individual daily flag without a recorded instant is silent with pilot $enabled', () async {
      await env.wipe();await LocalDb.instance;
      SharedPreferences.setMockInitialValues({});await Prefs.reload();
      await PilotFlags.set(PilotFlag.observations,enabled);
      final day=todayLabel();await LocalDb.putMetricSeriesValue(day,'irregular_rhythm_flag',1);
      final probe=_Probe();PulseAlertDelivery.probe=probe;
      await PulseAlertDelivery.run(individualDays:{day});
      expect(probe.events,hasLength(1));expect(probe.events.single.silent,enabled);
      expect(probe.events.single.date,day);
    });
    // catches: treating old recovered debt as a fresh audible finding.
    test('recovery summary silent follows pilot opt-in $enabled', () async {
      await env.wipe();await LocalDb.instance;
      SharedPreferences.setMockInitialValues({});await Prefs.reload();
      await PilotFlags.set(PilotFlag.observations,enabled);
      await LocalDb.putMetricSeriesValue('2026-11-01','irregular_rhythm_flag',1);
      final probe=_Probe();PulseAlertDelivery.probe=probe;
      await PulseAlertDelivery.run();
      expect(probe.events,hasLength(1));
      final event=probe.events.single;expect(event.silent,enabled);
      final details=NotificationService.instance.detailsForEvent(event);
      expect(details.android!.playSound,!enabled);
      expect(details.android!.enableVibration,!enabled);
      expect(details.android!.channelId.endsWith('_silent'),enabled);
      if(enabled) expect(details.iOS!.presentSound,false);
      await PulseAlertDelivery.run();expect(probe.events,hasLength(1));
    });
  }
}
