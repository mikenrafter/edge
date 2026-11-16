// Android's best-effort daily metadata worker. Independent of BLE/headless sync.
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import '../data/day_label.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../state/locale_controller.dart';
import 'update_service.dart';

Future<void> notifyRelease(ReleaseCandidate candidate) async {
  final l = await LocaleController.currentStrings();
  await NotificationCenter.instance.emit(
    NotificationEvent(
      dedupeKey: candidate.identity,
      category: NotifCategory.updates,
      title: candidate.separateApp ? l.updatesOfficialNew : l.updatesAvailable,
      body:
          '${l.updatesReleaseLabel(candidate.source == ReleaseSource.fork ? l.updatesFork : l.updatesOfficial, candidate.tag, candidate.prerelease ? l.updatesPrerelease : l.updatesStable)}${candidate.separateApp ? ' · ${l.updatesSeparateApp}' : ''}',
      date: todayLabel(),
      route: candidate.page.toString(),
    ),
    allowPermissionPrompt: false,
    phoneOnly: true,
  );
}

@pragma('vm:entry-point')
void updateCallbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task != updateTaskName) return true;
    UpdateService? service;
    try {
      service = await UpdateService.create(onRelease: notifyRelease);
      await service.check();
      return true;
    } catch (_) {
      // The next daily slot or a foreground check can retry. No retry loop.
      return true;
    } finally {
      service?.dispose();
    }
  });
}
