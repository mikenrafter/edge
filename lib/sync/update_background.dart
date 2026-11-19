// Android's best-effort daily release-metadata worker, the production wiring of
// the update checker, and the one function that turns a checked candidate into a
// notification. Independent of BLE and headless sync: nothing here opens LocalDb
// or runs band sync or derivation.
import 'dart:io';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:workmanager/workmanager.dart';

import '../data/day_label.dart';
import '../notify/alert_dispatcher.dart' show NotificationCenterDeliveryLedger;
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../state/locale_controller.dart';
import 'update_claim_ledger.dart';
import 'update_coordinator.dart';
import 'update_store.dart';

const updateTaskFrequency = Duration(days: 1);
const updateTaskNetworkType = NetworkType.unmetered;

const _environment = MethodChannel('openstrap/release_environment');
const _forkPackage = 'wtf.openstrap.openstrap_edge.dev';
const _officialPackage = 'wtf.openstrap.openstrap_edge';

/// Route the emitter's release claims through this install's UpdateStore. Safe
/// to call from any isolate, any number of times.
void registerUpdateLedgers() {
  final center = NotificationCenter.instance;
  if (!center.hasClaimLedger(NotifCategory.updates)) {
    center.registerClaimLedger(
      NotifCategory.updates,
      UpdateClaimLedger(UpdateStore.open),
    );
  }
  if (!NotificationCenterDeliveryLedger.hasRuleLedger('updates')) {
    NotificationCenterDeliveryLedger.registerRuleLedger(
      'updates',
      UpdateTargetLedger(UpdateStore.open),
    );
  }
}

/// Announce [candidate] through the shared emitter: claim ledger, central
/// quiet/sleep hold and destination routing all live there. Never prompts.
Future<void> notifyRelease(ReleaseCandidate candidate) async {
  registerUpdateLedgers();
  final l = await LocaleController.currentStrings();
  final source = candidate.source == ReleaseSource.fork
      ? l.updatesFork
      : l.updatesOfficial;
  final channel = candidate.prerelease ? l.updatesPrerelease : l.updatesStable;
  await NotificationCenter.instance.emit(
    NotificationEvent(
      dedupeKey: candidate.identity,
      category: NotifCategory.updates,
      title: candidate.separateApp ? l.updatesOfficialNew : l.updatesAvailable,
      body:
          '${l.updatesReleaseLabel(source, candidate.tag, channel)}'
          '${candidate.separateApp ? ' · ${l.updatesSeparateApp}' : ''}',
      date: todayLabel(),
      route: candidate.route,
    ),
    allowPermissionPrompt: false,
  );
}

/// The installed identity, checked once: package and version from
/// package_info_plus, ordered ABIs from the narrow native adapter, the compiled
/// mode. An unrecognized package or a missing adapter leaves identity unknown
/// rather than falling back to arm64/release.
Future<InstalledRelease> readInstalledRelease() async {
  final info = await PackageInfo.fromPlatform();
  List<String> abis = const [];
  if (Platform.isAndroid) {
    try {
      abis = await _environment.invokeListMethod<String>('abis') ?? const [];
    } on PlatformException {
      abis = const [];
    } on MissingPluginException {
      abis = const [];
    }
  }
  final known =
      Platform.isAndroid &&
      abis.isNotEmpty &&
      (info.packageName == _forkPackage || info.packageName == _officialPackage);
  return InstalledRelease(
    version: info.version,
    build: int.tryParse(info.buildNumber) ?? 0,
    fork: !known ? null : info.packageName == _forkPackage,
    mode: kProfileMode
        ? 'profile'
        : kReleaseMode
        ? 'release'
        : 'debug',
    abis: abis,
  );
}

Future<UpdateCoordinator> createUpdateCoordinator({
  Future<void> Function(ReleaseCandidate)? onRelease = notifyRelease,
}) async {
  final random = Random();
  return UpdateCoordinator(
    store: await UpdateStore.open(),
    client: http.Client(),
    clientFactory: () => http.Client(),
    installed: await readInstalledRelease(),
    unmetered: () async =>
        Platform.isAndroid &&
        (await _environment.invokeMethod<bool>('unmetered') ?? false),
    schedule: scheduleUpdateChecks,
    onRelease: onRelease,
    // Up to six hours, so installs do not all ask GitHub in the same minute.
    jitter: () => Duration(minutes: random.nextInt(6 * 60 + 1)),
  );
}

Future<void> scheduleUpdateChecks(bool enabled) async {
  if (!Platform.isAndroid) return;
  if (!enabled) {
    await Workmanager().cancelByUniqueName(updateTaskName);
    return;
  }
  await Workmanager().registerPeriodicTask(
    updateTaskName,
    updateTaskName,
    frequency: updateTaskFrequency,
    initialDelay: const Duration(hours: 1),
    constraints: Constraints(networkType: updateTaskNetworkType),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

@pragma('vm:entry-point')
void updateCallbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task != updateTaskName) return true;
    return runBackgroundUpdateCheck();
  });
}

/// The WorkManager check with injectable platform setup for wiring tests.
Future<bool> runBackgroundUpdateCheck({
  Future<UpdateCoordinator> Function() create = createUpdateCoordinator,
}) async {
  UpdateCoordinator? service;
  try {
    service = await create();
    await service.check();
    return true;
  } catch (_) {
    return true;
  } finally {
    service?.dispose();
  }
}

/// The app's handle on the checker: created on first need, never blocks launch,
/// and says so when it could not start. AppState forwards its changes.
class ReleaseChecks extends ChangeNotifier {
  UpdateCoordinator? coordinator;
  bool _failed = false;
  bool _closed = false;
  Future<void>? _loading;

  UpdateSnapshot get snapshot =>
      coordinator?.snapshot ??
      (_failed
          ? const UpdateSnapshot(
              phase: UpdatePhase.error,
              sources: {
                ReleaseSource.official: SourceUpdate(error: UpdateError.storage),
                ReleaseSource.fork: SourceUpdate(error: UpdateError.storage),
              },
            )
          : const UpdateSnapshot());

  Future<UpdateCoordinator?> ensure() async {
    await (_loading ??= _start().whenComplete(() => _loading = null));
    return coordinator;
  }

  Future<void> _start() async {
    if (coordinator != null) return;
    UpdateCoordinator? created;
    try {
      registerUpdateLedgers();
      created = await createUpdateCoordinator();
      await created.load();
      if (created.supported) await scheduleUpdateChecks(created.snapshot.enabled);
      if (_closed) {
        created.dispose();
        return;
      }
      coordinator = created;
      _failed = false;
      created.addListener(notifyListeners);
      notifyListeners();
      unawaited(created.check());
    } catch (_) {
      created?.dispose();
      _failed = true;
      if (!_closed) notifyListeners();
    }
  }

  /// App resume: cached results and the persisted daily deadline.
  Future<void> refresh() async {
    final c = coordinator;
    if (c == null) {
      await ensure();
    } else {
      await c.check();
    }
  }

  /// An eligible recovery pass of the shared alert policy.
  Future<void> releaseHeld() async => coordinator?.releaseHeld();

  @override
  void dispose() {
    _closed = true;
    coordinator?.removeListener(notifyListeners);
    coordinator?.dispose();
    super.dispose();
  }
}
