// Settings, and editing the profile.
//
// Two deliberate departures from the reference design:
//
//   · "Log out" is "Reset all data". Logging out of an app with no server is
//     theatre — it clears a session that does not exist while leaving every
//     byte on disk. The destructive action here is the honest one, and it says
//     what it destroys.
//   · Email, username, bio, location and date of birth are gone from the edit
//     form. None of them feed a metric, and a field that changes nothing is a
//     field that implies an account.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../compute/calc_power_policy.dart' show CalcPowerMode;
import '../../compute/derive_perf.dart' show DerivePerf;
import '../../data/off_lookup.dart';
import '../../health/health_export.dart' show HealthLinkState;
import '../../health/health_import_state.dart';
import '../../health/health_profile_import.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/tasker_bridge.dart';
import '../../haptics/band_queue.dart'
    show kBandCommandLimitMax, kBandCommandLimitMin;
import '../../haptics/builtin_patterns.dart' show alertSystemKey;
import '../../haptics/haptic_slots.dart' show slotPatternLabel;
import '../../haptics/pattern_store.dart' show SavedHapticPattern;
import '../../notify/alert_rule.dart';
import '../../notify/buzz_sequence.dart';
import '../../notify/notification_prefs.dart';
import '../../notify/notification_service.dart';
import '../../settings/settings_repository.dart';
import '../../platform/app_icon.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/locale_controller.dart';
import '../../state/prefs.dart';
import '../../state/units_controller.dart';
import '../../telemetry/health_uploader.dart';
import '../../theme/theme_controller.dart';
import '../activity/zones.dart' show ZonesDetail;
import '../screens/coach.dart' show CoachSetup, coachSubtitle;
import '../screens/explorer.dart' show ExplorerScreen;
import '../ui2.dart';
import 'alarm.dart';
import 'band_notifications.dart';
import 'buzz_pattern.dart';
import 'data.dart';
import 'device_lab.dart' show DeviceLab;
import 'devices.dart' show MyDevices;
import 'gallery.dart';
import 'gesture_failures.dart';
import 'gestures.dart';
import 'haptics_settings.dart';
import 'live_devices.dart' show LiveDevices;
import 'pattern_picker.dart';
import 'profile.dart';

/// Unwind the profile stack back to the gate.
///
/// `_Gate` is `MaterialApp.home` — the BOTTOM of the navigator stack — so an
/// action that changes `AppState.route` swaps what is under everything without
/// popping any of it. Resetting all data, forgetting the band and asking to
/// pair again are all route changes taken from a pushed screen, and all three
/// used to leave the user staring at the screen they tapped from, describing a
/// state that no longer existed.
void backToRoot(BuildContext c) =>
    Navigator.of(c).popUntil((r) => r.isFirst);

// ══════════════════ MORE SETTINGS ══════════════════

/// Taps on the version row that reveal the developer group. The conventional
/// gesture, for the conventional reason: it is discoverable by anyone who
/// already knows it and invisible to everyone else.
const kDevTaps = 7;

class MoreSettings extends StatefulWidget {
  const MoreSettings({super.key});

  @override
  State<MoreSettings> createState() => _MoreSettingsState();
}

class _MoreSettingsState extends State<MoreSettings> {
  /// Whether a food barcode may be looked up online. Not on AppState: it is a
  /// screen-local preference like the map basemap's, read straight off Prefs.
  bool _barcode = offLookupAllowed;

  /// Home's pull-to-sync, read straight off Prefs like [_barcode].
  bool _pullToSync = Prefs.pullToSyncOn;

  /// The developer's band haptic command limit, mirrored from Prefs.
  int _hapticLimit = Prefs.hapticCommandLimit;
  String _version = '';
  int _taps = 0;

  /// The home-screen icon, asked of the OS rather than stored — see
  /// lib/platform/app_icon.dart. Null until the answer arrives, and the row is
  /// not drawn at all where the OS cannot change it.
  AppIconChoice? _icon;

  /// The database file size for the Storage row. Null until read.
  int? _storageBytes;

  @override
  void initState() {
    super.initState();
    _readVersion();
    _readIcon();
    _readStorage();
  }

  Future<void> _readStorage() async {
    try {
      final bytes = await context.read<AppState>().dataFileBytes();
      if (mounted) setState(() => _storageBytes = bytes);
    } catch (_) {/* no size, no number — the row prints nothing */}
  }

  /// An import or a restore changes the file, so the size is read again once
  /// the data screen is left.
  Future<void> _openData() async {
    await goto(context, const DataScreen());
    if (mounted) await _readStorage();
  }

  Future<void> _readIcon() async {
    if (!await AppIcon.available()) return;
    final now = await AppIcon.current();
    if (mounted) setState(() => _icon = now);
  }

  /// iOS puts up its own confirmation alert, so there is nothing to confirm
  /// here — but it can also be refused, and a refused change must not be drawn
  /// as if it happened. The row re-reads the OS either way.
  Future<void> _pickIcon(AppIconChoice choice) async {
    if (choice == _icon) return;
    await AppIcon.set(choice);
    final now = await AppIcon.current();
    if (mounted) setState(() => _icon = now);
  }

  /// Applied even if the screen was left meanwhile: the user chose it.
  Future<void> _pickCalcPower(AppState app) async {
    final m = await pickCalcPowerMode(context, app.calcPowerMode);
    if (m != null && m != app.calcPowerMode) await app.setCalcPowerMode(m);
  }

  Future<void> _editSleepSchedule(AppState app) =>
      editExpectedSleepSchedule(context, app);

  Future<void> _readVersion() async {
    try {
      final i = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${i.version} (${i.buildNumber})');
    } catch (_) {/* no version, no row — and no way in */}
  }

  void _tapVersion() {
    if (context.capsRead.has(Feature.developerMode) || ++_taps < kDevTaps) {
      return;
    }
    _setDev(true);
  }

  /// The one preference here that is awaited. A revocation that never reached
  /// storage is back ON at the next launch, so it does not get to fail quietly
  /// — the switch still moves (in-session it really is off, nothing is sent),
  /// and the person is told it did not stick.
  Future<void> _toggleBarcode(BuildContext c) async {
    final want = !_barcode;
    final messenger = ScaffoldMessenger.of(c);
    final saved = await setOffLookupAllowed(want);
    if (!mounted) return;
    setState(() => _barcode = want);
    if (!saved) {
      final l = AppLocalizations.of(context);
      messenger.showSnackBar(SnackBar(
        content: Text(l?.settingsBarcodeSaveFailed ??
            'The setting was not saved. It may revert when you '
            'reopen the app.'),
      ));
    }
  }

  void _setDev(bool on) {
    context.read<AppState>().setDevMode(on);
    setState(() => _taps = 0);
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final units = c.watch<UnitsController>();
    final theme = c.watch<ThemeController>();
    final caps = c.caps;
    return MoreSettingsView(
      version: _version,
      devMode: caps.has(Feature.developerMode),
      hapticCommandLimit: _hapticLimit,
      onHapticCommandLimit: (v) {
        // Read at every use by the band's ledger: it takes effect at once.
        Prefs.setHapticCommandLimit(v);
        setState(() => _hapticLimit = Prefs.hapticCommandLimit);
      },
      // The engine's `last_pass_perf`: measured values only.
      lastCalculation: DerivePerf.describe(app.lastPassPerf),
      onVersionTap: _tapVersion,
      onToggleDev: () => _setDev(false),
      onGallery: () => goto(c, const GalleryScreen()),
      units: units.system.label,
      appearance: theme.choice.label,
      cycleTracking: app.cycleTrackingEnabled,
      appIcon: _icon,
      onPickIcon: _pickIcon,
      telemetry: app.telemetryConsent,
      barcodeLookup: _barcode,
      pullToSync: _pullToSync,
      onTogglePullToSync: () {
        Prefs.setBool(Prefs.pullToSync, !_pullToSync);
        setState(() => _pullToSync = !_pullToSync);
      },
      // Shown when the build has the feature OR when this install already
      // consented under an older build. A consent that cannot be withdrawn is
      // not consent, and the old `lib/ui` toggle died with that package while
      // the pref — and the daily whole-database upload it authorises — did not.
      showHealthShare: caps.has(Feature.healthShare),
      healthShare: app.healthShareConsent,
      healthStore: app.healthStoreName,
      healthSync: app.healthSyncEnabled,
      healthState: app.healthState,
      showUpdateChecks: caps.has(Feature.updateChecks),
      updateChecks: app.updateChecksEnabled,
      updateAvailable: app.updateAvailable,
      updateMandatory: app.updateMandatory,
      expectedSleepSchedule: app.sleepOperations.schedule,
      onEditSleepSchedule: () => _editSleepSchedule(app),
      storageBytes: _storageBytes,
      onEditProfile: () => goto(c, const EditProfile()),
      onDevices: () => goto(c, const MyDevices()),
      onLiveDevices: () => goto(c, const LiveDevices()),
      onDeviceLab: () => goto(c, const DeviceLab()),
      onDataExplorer: () => goto(c, const ExplorerScreen()),
      onCoach: () => goto(c, const CoachSetup()),
      relaySupported: caps.has(Feature.relayEntry),
      onAlarm: () => goto(c, const AlarmScreen()),
      onBandNotifications: () => goto(c, const BandNotifications()),
      onGestures: () => goto(c, const BandGestures()),
      onHaptics: () => goto(c, const HapticsSettings()),
      onGestureFailures: () => goto(c, const GestureFailures()),
      onNotifications: () => goto(c, const NotificationSettings()),
      onData: _openData,
      calcPowerMode: app.calcPowerMode,
      onPickCalcPowerMode: () => _pickCalcPower(app),
      onAutomation: () => goto(c, const AutomationSettings()),
      onCycleUnits: () => units.setSystem(units.isImperial
          ? UnitSystem.metric
          : UnitSystem.imperial),
      onCycleAppearance: () => theme.setChoice(AppThemeChoice.values[
          (theme.choice.index + 1) % AppThemeChoice.values.length]),
      onToggleCycleTracking: () =>
          app.setCycleTrackingEnabled(!app.cycleTrackingEnabled),
      onToggleTelemetry: () => app.setTelemetryConsent(!app.telemetryConsent),
      onToggleBarcodeLookup: () => _toggleBarcode(c),
      onToggleHealthShare: () => _toggleHealthShare(c, app),
      onToggleHealthSync: () => _toggleHealthSync(app),
      onToggleUpdateChecks: () =>
          app.setUpdateChecksEnabled(!app.updateChecksEnabled),
    );
  }
}

/// The language row's sub-line. Without a [LocaleController] above (a view
/// pumped on its own) it reads as the system default, like coachSubtitle does
/// for the coach.
String _languageSub(BuildContext c) {
  try {
    return languageLabel(c, c.watch<LocaleController>().code);
  } catch (_) {
    return languageLabel(c, null);
  }
}

String _clock(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';

/// Pick the home-screen icon, with both options drawn so the choice is made by
/// looking rather than by reading a word.
///
/// Not a [SetRow]: a cycling value row would flip the icon on every tap, and
/// each flip on iOS is a system confirmation alert. Two targets, one tap, no
/// wrong taps to undo.
class _IconRow extends StatelessWidget {
  final AppIconChoice chosen;
  final ValueChanged<AppIconChoice>? onPick;

  const _IconRow({required this.chosen, this.onPick});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: p.wash(C.indigo), borderRadius: R.rSm),
          child: Icon(LucideIcons.image, size: 16, color: p.on(C.indigo)),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l?.settingsIconRowTitle ?? 'Icon',
                style: F.body.copyWith(color: p.ink)),
            // The cost, stated where the choice is made. iOS shows its own
            // alert on every change and there is no way to turn that off.
            Text(l?.settingsIconRowConfirmHint ?? 'iPhone will ask you to confirm',
                style: F.over.copyWith(color: p.ink3)),
          ]),
        ),
        const SizedBox(width: S.x2),
        for (final choice in AppIconChoice.values) ...[
          if (choice != AppIconChoice.values.first) const SizedBox(width: S.x2),
          _IconChoice(
            choice: choice,
            selected: choice == chosen,
            onTap: onPick == null ? null : () => onPick!(choice),
          ),
        ],
      ]),
    );
  }
}

class _IconChoice extends StatelessWidget {
  final AppIconChoice choice;
  final bool selected;
  final VoidCallback? onTap;

  const _IconChoice(
      {required this.choice, required this.selected, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    // Decoded at the size it is drawn at: the source is the 1024 px launcher
    // master, and decoding that in full to paint a 36 pt thumbnail is 4 MB of
    // bitmap per option.
    final px = (36 * MediaQuery.devicePixelRatioOf(c)).round();
    return Pressable(
      onTap: onTap,
      semanticLabel:
          '${l?.settingsIconChoiceLabel(choice.label) ?? '${choice.label} icon.'}'
          '${selected ? (l?.settingsSelectedSuffix ?? ' Selected.') : ''}',
      child: Container(
        padding: const EdgeInsets.all(S.x1 / 2),
        decoration: BoxDecoration(
          borderRadius: R.rMd,
          border: Border.all(
              color: selected ? p.on(C.indigo) : p.line, width: selected ? 2 : 1),
        ),
        child: ClipRRect(
          borderRadius: R.rSm,
          child: Image.asset(choice.asset,
              width: 36, height: 36, cacheWidth: px, cacheHeight: px),
        ),
      ),
    );
  }
}

/// Turn the Apple Health / Health Connect EXPORT on or off.
///
/// `setHealthSync` already requests the OS permission and kicks a first sync;
/// this row is the only thing that was ever missing. Until it existed the app
/// shipped a write entitlement, a usage string and ten Android WRITE_*
/// permissions for a code path that could not run — see
/// docs/internal/UNREACHABLE.md P1.
///
/// Health Connect has two failure modes that are not refusals and must not be
/// reported as one: it may not be installed, or it may be too old. Both are
/// answered with the action that fixes them rather than an error.
Future<void> _toggleHealthSync(AppState app) async {
  if (app.healthSyncEnabled) {
    await app.setHealthSync(false);
    return;
  }
  await app.setHealthSync(true);
  switch (app.healthState) {
    case HealthLinkState.notInstalled:
    case HealthLinkState.needsUpdate:
      await app.installHealthConnect();
    case HealthLinkState.needsPermission:
      // Android only sends the user to Health Connect's own screen; on iOS
      // there is nothing to open, and `openSettings` is a no-op there.
      await app.openHealthConnect();
    case HealthLinkState.ready:
    case HealthLinkState.unsupported:
    case HealthLinkState.unknown:
      break;
  }
}

/// One line saying what the export is actually doing right now.
String healthSyncSub(
    BuildContext c, bool on, HealthLinkState state, String store) {
  final l = AppLocalizations.of(c);
  if (!on) {
    return l?.settingsHealthSyncOff(store) ?? 'Off. Nothing is written to $store';
  }
  return switch (state) {
    HealthLinkState.ready => l?.settingsHealthSyncReady(store) ??
        "Writes each day's sleep, resting heart rate, HRV, respiratory rate, "
        "energy and workouts to $store once the day is final",
    HealthLinkState.needsPermission =>
      l?.settingsHealthSyncNeedsPermission(store) ??
          '$store has not granted write access. Tap to open it',
    HealthLinkState.notInstalled => l?.settingsHealthSyncNotInstalled ??
        'Health Connect is not installed. Tap to '
            'get it',
    HealthLinkState.needsUpdate => l?.settingsHealthSyncNeedsUpdate ??
        'Health Connect needs an update before the app can write to it. Tap to update',
    HealthLinkState.unsupported => l?.settingsHealthSyncUnsupported ??
        'This device has no health store to write to',
    HealthLinkState.unknown =>
      l?.settingsHealthSyncChecking(store) ?? 'Checking $store…',
  };
}

/// Grant or withdraw the whole-database health contribution.
///
/// Asymmetric on purpose. Granting is confirmed first — it authorises a daily
/// upload of the ENTIRE database, raw signal included, which is the largest
/// thing this app can ever send anywhere. Withdrawing takes effect
/// IMMEDIATELY, with no dialog in the way, and only then says what had already
/// been sent: a revocation you have to confirm is a revocation that can be
/// mis-tapped into staying on.
Future<void> _toggleHealthShare(BuildContext c, AppState app) async {
  if (app.healthShareConsent) {
    await app.setHealthShareConsent(false);
    final last = await HealthUploader.instance.lastUploadAt();
    if (!c.mounted) return;
    final l = AppLocalizations.of(c);
    await showDialog<void>(
      context: c,
      builder: (d) => AlertDialog(
        title: Text(l?.settingsHealthShareOffTitle ?? 'Contribution off'),
        content: Text(
          last == null
              ? (l?.settingsHealthShareOffNeverUploaded ??
                  'No data was uploaded, and none will be.')
              // What we KNOW, not what we hope: the revocation is posted
              // once, unawaited, with no retry queue, so offline it never
              // arrives and nothing here can tell.
              : (l?.settingsHealthShareOffDetail(
                      last.toLocal().toString().split('.').first) ??
                  'Nothing further will be uploaded.\n\n'
                      'One copy of your database was uploaded on '
                      '${last.toLocal().toString().split('.').first}. The server keeps only the most recent copy per device. '
                      'The app sent a withdrawal message once and does not retry it. '
                      'If this phone was offline, the message did not arrive, and the app cannot confirm the copy is deleted.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(d).pop(),
              child: Text(l?.settingsOk ?? 'OK')),
        ],
      ),
    );
    return;
  }
  final l = AppLocalizations.of(c);
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(
          l?.settingsHealthShareOnTitle ?? 'Contribute your health data?'),
      content: Text(
        l?.settingsHealthShareOnBody ??
            'Once a day, on Wi-Fi and while charging, the app uploads a compressed copy of '
            'your entire database: every derived day and every raw sensor '
            'row the band has sent. The data is used to improve the algorithms.\n\n'
            'The upload is not anonymous. It contains your whole health '
            'history. You can switch this off at any time, and nothing further '
            'is sent after that.',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.settingsNo ?? 'No')),
        TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l?.settingsContribute ?? 'Contribute')),
      ],
    ),
  );
  if (ok == true) await app.setHealthShareConsent(true);
}

/// Two time pickers, seeded from the saved schedule (or 23:00 / 07:00). Works
/// with no data at all: it writes the schedule, not a night. Shared by Settings
/// and the alarm screen (Natural Wake needs it).
Future<void> editExpectedSleepSchedule(BuildContext context, AppState app) async {
  final cur = app.sleepOperations.schedule;
  TimeOfDay at(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60);
  final bed = await showTimePicker(
    context: context,
    initialTime: at(cur?.onsetMinute ?? 23 * 60),
    helpText: 'WHEN YOU USUALLY GO TO BED',
  );
  if (bed == null || !context.mounted) return;
  final up = await showTimePicker(
    context: context,
    initialTime: at(cur?.wakeMinute ?? 7 * 60),
    helpText: 'WHEN YOU USUALLY GET UP',
  );
  if (up == null || !context.mounted) return;
  await app.setExpectedSleepSchedule(ExpectedSleepSchedule(
    onsetMinute: bed.hour * 60 + bed.minute,
    wakeMinute: up.hour * 60 + up.minute,
  ));
}

class MoreSettingsView extends StatelessWidget {
  final String units, appearance;
  final bool telemetry, barcodeLookup, cycleTracking;

  /// Home's pull down to sync. On by default.
  final bool pullToSync;
  final VoidCallback? onTogglePullToSync;

  /// The home-screen icon, or null where the OS will not change it — Android,
  /// and the managed iOS configurations that refuse. Null means the row is not
  /// drawn: a control that cannot do its one job is worse than no control.
  final AppIconChoice? appIcon;
  final ValueChanged<AppIconChoice>? onPickIcon;

  /// Settings > Data & privacy > Calculations: when derive work and warming run.
  final CalcPowerMode calcPowerMode;
  final VoidCallback? onPickCalcPowerMode;

  /// The health-contribution row appears only where it means something: a
  /// build that has the feature, or an install that already said yes to it.
  final bool showHealthShare, healthShare;

  /// The platform health EXPORT. `healthStore` names it — "Apple Health" or
  /// "Health Connect" — because "your health app" is not something a user can
  /// go and grant a permission in.
  final bool healthSync;
  final HealthLinkState healthState;
  final String healthStore;

  /// The update-check row appears only on a build that can check.
  final bool showUpdateChecks, updateChecks;

  /// What the last check ANSWERED. The check itself was already running and
  /// already storing its answer; this row is the only place in the app that
  /// says what it found, so without these two the whole poll was a no-op.
  final bool updateAvailable, updateMandatory;

  /// `0.9.26 (57)`, or empty until package_info answers — the About group is
  /// the whole reveal gesture, so it is not drawn against a blank.
  final String version;

  /// Off by default and off on every fresh install. The group it gates is not
  /// a feature: nothing in it is for anyone who has not deliberately asked.
  final bool devMode;

  /// Developer group: the band haptic command limit per 2 minutes (10..60) and
  /// the change callback.
  final int hapticCommandLimit;
  final ValueChanged<int>? onHapticCommandLimit;

  /// The Developer group's "Last calculation" line, already worded; an em dash
  /// until a pass has been measured.
  final String lastCalculation;

  final VoidCallback? onVersionTap, onToggleDev, onGallery;

  /// The expected sleep schedule (local clock times), or null when never set.
  /// The row is always drawn: it needs no data.
  final ExpectedSleepSchedule? expectedSleepSchedule;
  final VoidCallback? onEditSleepSchedule;

  /// Android only, like the relay itself: where it cannot run, the App
  /// notifications on the band row is omitted rather than shown against
  /// nothing.
  final bool relaySupported;

  /// The size of the database file, or null while it is still being read: the
  /// Storage row prints nothing rather than a zero it does not know.
  final int? storageBytes;

  final VoidCallback? onEditProfile,
      onDevices,
      onLiveDevices,
      onDeviceLab,
      onDataExplorer,
      onCoach,
      onAlarm,
      onBandNotifications,
      onGestures,
      onHaptics,
      onGestureFailures,
      onNotifications,
      onData,
      onAutomation,
      onCycleUnits,
      onCycleAppearance,
      onToggleTelemetry,
      onToggleBarcodeLookup,
      onToggleCycleTracking,
      onToggleHealthShare,
      onToggleHealthSync,
      onToggleUpdateChecks;

  const MoreSettingsView({
    super.key,
    this.units = 'Metric',
    this.appearance = 'System',
    this.appIcon,
    this.onPickIcon,
    this.pullToSync = true,
    this.onTogglePullToSync,
    this.calcPowerMode = CalcPowerMode.balanced,
    this.onPickCalcPowerMode,
    this.healthSync = false,
    this.healthState = HealthLinkState.unknown,
    this.healthStore = 'Apple Health',
    this.telemetry = false,
    this.barcodeLookup = true,
    this.cycleTracking = false,
    this.showHealthShare = false,
    this.healthShare = false,
    this.showUpdateChecks = false,
    this.updateChecks = true,
    this.updateAvailable = false,
    this.updateMandatory = false,
    this.version = '',
    this.devMode = false,
    this.hapticCommandLimit = 30,
    this.onHapticCommandLimit,
    this.lastCalculation = '—',
    this.onVersionTap,
    this.onToggleDev,
    this.onGallery,
    this.expectedSleepSchedule,
    this.onEditSleepSchedule,
    this.relaySupported = false,
    this.storageBytes,
    this.onEditProfile,
    this.onDevices,
    this.onLiveDevices,
    this.onDeviceLab,
    this.onDataExplorer,
    this.onCoach,
    this.onAlarm,
    this.onBandNotifications,
    this.onGestures,
    this.onHaptics,
    this.onGestureFailures,
    this.onNotifications,
    this.onData,
    this.onAutomation,
    this.onCycleUnits,
    this.onCycleAppearance,
    this.onToggleTelemetry,
    this.onToggleBarcodeLookup,
    this.onToggleCycleTracking,
    this.onToggleHealthShare,
    this.onToggleHealthSync,
    this.onToggleUpdateChecks,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final on = l?.stateOn ?? 'On';
    final off = l?.stateOff ?? 'Off';
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsNavTitle ?? 'Settings'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                // Grouped by task. This is the landing screen:
                // every row has exactly one door here. Your own preferences
                // come first and Community sits just above Connections.
                // Hardware keeps the id `settings_band` it was saved under as
                // "Band", so a section somebody folded stays folded.
                SettingsAccordion('You & preferences',
                    id: 'settings_preferences',
                    children: [
                  SetRow(LucideIcons.userPen, C.purple,
                      l?.profileEditProfile ?? 'Edit profile',
                      sub: l?.profileEditProfileSub ??
                          'Sex, age, height, weight',
                      onTap: onEditProfile),
                  Builder(builder: (c) => SetRow(
                      LucideIcons.languages, C.blue,
                      AppLocalizations.of(c)?.profileLanguage ?? 'Language',
                      sub: _languageSub(c),
                      onTap: () => pickLanguage(c))),
                  SetRow(LucideIcons.ruler, C.blue,
                      l?.settingsUnitsRowTitle ?? 'Units',
                      value: units, onTap: onCycleUnits),
                  SetRow(LucideIcons.sun, C.yellow,
                      l?.settingsAppearanceRowTitle ?? 'Appearance',
                      value: appearance, onTap: onCycleAppearance),
                  // Home's pull-to-refresh. Off removes the gesture; the sync
                  // status line on Home keeps its Sync now button either way.
                  SetRow(LucideIcons.refreshCw, C.blue, 'Pull down to sync',
                      sub: 'Pull Home down to sync with the band',
                      value: pullToSync ? on : off,
                      onTap: onTogglePullToSync),
                  // Intentionally also in Alarm > Wake, where it is the alarm's
                  // input in context. Both rows edit the same preference.
                  SetRow(LucideIcons.moon, C.indigo, 'Expected sleep schedule',
                      sub: 'Your usual bed and wake times',
                      value: expectedSleepSchedule == null
                          ? 'Not set'
                          : '${_clock(expectedSleepSchedule!.onsetMinute)} to '
                              '${_clock(expectedSleepSchedule!.wakeMinute)}',
                      onTap: onEditSleepSchedule),
                  if (appIcon != null)
                    _IconRow(chosen: appIcon!, onPick: onPickIcon),
                  // Opt-in, and it says what it does rather than what it is
                  // about — "Cycle tracking" alone leaves you guessing whether
                  // switching it off throws the entries away.
                  SetRow(LucideIcons.droplet, C.pink,
                      l?.settingsCycleTrackingRowTitle ?? 'Cycle tracking',
                      sub: l?.settingsCycleTrackingRowSub ??
                          'Adds the Cycle tab to Wellness. Off hides it and '
                              'keeps everything already logged',
                      value: cycleTracking ? on : off,
                      onTap: onToggleCycleTracking),
                ]),
                SettingsAccordion('Hardware', id: 'settings_band', children: [
                  SetRow(LucideIcons.watch, C.blue,
                      l?.profileMyDevices ?? 'My devices',
                      sub: 'Pair, rename and manage your band',
                      onTap: onDevices),
                  SetRow(LucideIcons.hand, C.orange, 'Gestures',
                      sub: l?.settingsDoubleTapRowSub ??
                          'What a double-tap on the band does',
                      onTap: onGestures),
                  // The named buzz patterns and the band's safety limits.
                  SetRow(LucideIcons.vibrate, C.purple, 'Haptics',
                      key: const ValueKey('settings-haptics'),
                      sub: 'Your buzz patterns and band safety',
                      onTap: onHaptics),
                  // Gestures that failed to activate, with the log to send.
                  // Always drawn: an empty list says so.
                  SetRow(LucideIcons.triangleAlert, C.orange, 'Gesture failures',
                      key: const ValueKey('settings-gesture-failures'),
                      sub: 'Saved logs of gestures that did not activate',
                      onTap: onGestureFailures),
                ]),
                SettingsAccordion('Alerts', id: 'settings_alerts', children: [
                  // The alarm's one door: a row here, not a row inside
                  // the Alerts and notifications screen.
                  SetRow(LucideIcons.alarmClock, C.orange,
                      l?.settingsAlarmRowTitle ?? 'Alarm',
                      sub: l?.settingsAlarmRowSub ??
                          'Buzzes on your wrist and runs on the band\'s clock',
                      onTap: onAlarm),
                  SetRow(LucideIcons.bell, C.blue,
                      l?.settingsManageNotificationsRowTitle ??
                          'Alerts and notifications',
                      sub: l?.settingsManageNotificationsRowSub ??
                          'Turn alerts on or off and set '
                          'quiet hours',
                      onTap: onNotifications),
                  // The one door to the relay screen. Android-only and
                  // omitted elsewhere rather than shown against nothing.
                  if (relaySupported)
                    SetRow(LucideIcons.bellRing, C.purple,
                        'App notifications on the band',
                        sub: 'Which apps, alarms and calls make the band buzz',
                        onTap: onBandNotifications),
                ]),
                SettingsAccordion('Data & privacy',
                    id: 'settings_data_privacy',
                    children: [
                  SetRow(LucideIcons.database, C.green,
                      l?.profileStorage ?? 'Storage',
                      value: storageBytes == null
                          ? ''
                          : formatBytes(storageBytes!),
                      chevron: false),
                  SetRow(LucideIcons.download, C.green,
                      l?.settingsExportBackupImportRowTitle ??
                          'Export, backup, import',
                      sub: l?.settingsExportBackupImportRowSub ??
                          'Export spreadsheets or a full copy, and import history',
                      onTap: onData),
                  SetRow(LucideIcons.batteryCharging, C.green, 'Calculations',
                      key: const ValueKey('calc-power-row'),
                      value: calcPowerLabels[calcPowerMode]!,
                      onTap: onPickCalcPowerMode),
                  // The row P1 was missing. Everything behind it — the
                  // permission request, the retry/backoff, the four gates —
                  // was already written and simply had no way to be switched
                  // on, so the write entitlement and usage strings described a
                  // path that could not run.
                  SetRow(LucideIcons.heartPulse, C.red,
                      l?.settingsWriteToHealthStoreRowTitle(healthStore) ??
                          'Write to $healthStore',
                      sub: healthSyncSub(c, healthSync, healthState, healthStore),
                      value: healthSync ? on : off,
                      onTap: onToggleHealthSync),
                  if (showHealthShare)
                    SetRow(LucideIcons.cloudUpload, C.red,
                        l?.settingsContributeHealthDataRowTitle ??
                            'Contribute my health data',
                        sub: l?.settingsContributeHealthDataRowSub ??
                            'Uploads your whole database once a day, on '
                                'Wi-Fi and charging, to improve the algorithms',
                        value: healthShare ? on : off,
                        onTap: onToggleHealthShare),
                  SetRow(LucideIcons.bug, C.orange,
                      l?.settingsCrashReportsRowTitle ?? 'Crash reports',
                      sub: l?.settingsCrashReportsRowSub ??
                          'Reports are sent only if you opt in',
                      value: telemetry ? on : off,
                      onTap: onToggleTelemetry),
                ]),
                SettingsAccordion(
                    l?.profileCommunityGroup ?? 'Community',
                    id: 'settings_community',
                    children: [
                  SetRow.brand(brandGlyph('assets/icons/github.svg'), C.n500,
                      l?.profileGithubTitle ?? 'GitHub',
                      sub: l?.profileGithubSub ??
                          'Star the project to show support.',
                      onTap: () => open3rdPartyLink(kGithubUrl)),
                  SetRow.brand(brandGlyph('assets/icons/reddit.svg'), C.orange,
                      l?.profileRedditTitle ?? 'Reddit',
                      sub: l?.profileRedditSub ??
                          'Join r/OpenStrap to share results and ask questions.',
                      onTap: () => open3rdPartyLink(kRedditUrl)),
                  SetRow.brand(brandGlyph('assets/icons/discord.svg'),
                      C.indigo, l?.profileDiscordTitle ?? 'Discord',
                      sub: l?.profileDiscordSub ??
                          'Chat with other users and the developers.',
                      onTap: () => open3rdPartyLink(kDiscordUrl)),
                  SetRow(LucideIcons.heartHandshake, C.pink,
                      l?.profileSponsorTitle ?? 'Sponsor',
                      sub: l?.profileSponsorSub ??
                          'This is a free, open-source project. Sponsoring funds development.',
                      onTap: () => open3rdPartyLink(kSponsorUrl)),
                ]),
                SettingsAccordion('Connections',
                    id: 'settings_connections',
                    children: [
                  // THE ONLY DOOR TO THE COACH'S SETUP: Home's sparkles button
                  // is gated on `coachReady`, so on a fresh install there is
                  // no icon to find it behind. `watch` rather than `read` so
                  // the sub-line stops saying "Not set up" the moment it is.
                  Builder(builder: (c) => SetRow(
                      LucideIcons.sparkles, C.purple,
                      AppLocalizations.of(c)?.profileAiCoach ?? 'AI coach',
                      sub: coachSubtitle(c) ??
                          (AppLocalizations.of(c)?.profileNotSetUp ??
                              'Not set up'),
                      onTap: onCoach)),
                  SetRow(LucideIcons.workflow, C.indigo,
                      l?.settingsTaskerShortcutsRowTitle ??
                          'Tasker and Shortcuts',
                      // The row states the asymmetry rather than leaving it to
                      // the screen: someone on an iPhone should learn what they
                      // are not getting before they tap into it.
                      sub: l?.settingsTaskerShortcutsRowSub ??
                          'Android can send events out. iOS can buzz the band '
                          'but cannot receive events from it',
                      onTap: onAutomation),
                  if (showUpdateChecks)
                    SetRow(LucideIcons.refreshCw, C.blue,
                        l?.settingsCheckForUpdatesRowTitle ??
                            'Check for updates',
                        sub: updateMandatory
                            ? (l?.settingsUpdateBelowMinimum ??
                                'This build is below the minimum supported '
                                    'build. Install the newer release from GitHub')
                            : updateAvailable
                                ? (l?.settingsUpdateAvailable ??
                                    'A newer build is published on GitHub')
                                : (l?.settingsUpdateCheckSub ??
                                    'Asks the release server on launch. It sees '
                                        'your IP address and when you open the app'),
                        value: updateChecks ? on : off,
                        onTap: onToggleUpdateChecks),
                  // The food log's one outbound call. Named by what it sends,
                  // not by the feature it powers — a scan is the only thing
                  // that triggers it and the barcode is the whole payload.
                  SetRow(LucideIcons.scanBarcode, C.domFood,
                      l?.settingsBarcodeLookupRowTitle ??
                          'Look barcodes up online',
                      sub: l?.settingsBarcodeLookupRowSub ??
                          'Sends a scanned barcode to openfoodfacts.org. '
                          'It sees the barcode and your IP address, nothing else about you',
                      value: barcodeLookup ? on : off,
                      onTap: onToggleBarcodeLookup),
                ]),
                SettingsAccordion(l?.settingsGroupAbout ?? 'About',
                    id: 'settings_about',
                    children: [
                  if (version.isNotEmpty)
                    SetRow(LucideIcons.info, C.n500,
                        l?.settingsVersionRowTitle ?? 'Version',
                        value: version, chevron: false, onTap: onVersionTap),
                  // Where the licences of what this app uses are written out
                  // in full. Open Food Facts' ODbL asks for the notice to be
                  // reachable, not only for the credit beside the numbers.
                  SetRow(LucideIcons.scale, C.n500,
                      l?.settingsNoticesLicencesRowTitle ??
                          'Notices and licences',
                      sub: l?.settingsNoticesLicencesRowSub ??
                          'Affiliations and data sources',
                      onTap: () => launchUrl(
                          Uri.parse(
                              'https://openstrap.github.io/edge/notice.html'),
                          mode: LaunchMode.externalApplication)),
                ]),
                if (devMode)
                  SettingsAccordion(l?.settingsGroupDeveloper ?? 'Developer',
                      id: 'settings_developer',
                      children: [
                    SetRow(LucideIcons.layoutGrid, C.purple,
                        l?.settingsComponentGalleryRowTitle ??
                            'Component gallery',
                        sub: l?.settingsComponentGalleryRowSub ??
                            'Every component, at any text scale, in either '
                                'theme',
                        onTap: onGallery),
                    SetRow(LucideIcons.activity, C.red, 'Live devices',
                        sub: 'The last 30 seconds from each connected device',
                        onTap: onLiveDevices),
                    // The lab's tap tools are still behind
                    // FeatureFlag.tapClassifiers inside it; the entry itself
                    // needs dev mode, which this group already is.
                    SetRow(LucideIcons.flaskConical, C.purple, 'Device lab',
                        sub: 'Try gestures the band does not report on its own',
                        onTap: onDeviceLab),
                    // Not a Health tab yet: up to four metrics on one time axis.
                    SetRow(LucideIcons.chartLine, C.blue, 'Data Explorer',
                        sub: 'Compare up to four metrics on one time axis',
                        onTap: onDataExplorer),
                    _HapticLimitRow(
                        limit: hapticCommandLimit,
                        onChanged: onHapticCommandLimit),
                    SetRow(LucideIcons.timer, C.n500, 'Last calculation',
                        sub: lastCalculation, chevron: false),
                    SetRow(LucideIcons.code, C.n500,
                        l?.settingsDeveloperModeRowTitle ?? 'Developer mode',
                        value: on, chevron: false, onTap: onToggleDev),
                  ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Developer group: how many haptic commands the band may be sent in any 2
/// minutes. A precaution we chose (motor wear, battery), not a limit of the
/// band's hardware, so it says the number in force and why.
class _HapticLimitRow extends StatelessWidget {
  const _HapticLimitRow({required this.limit, this.onChanged});
  final int limit;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      key: const ValueKey('developer-haptic-limit'),
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Band haptic limit', style: F.body.copyWith(color: p.ink)),
        Text(
            '$limit commands in any 2 minutes. A precaution we chose to spare '
            'the motor and the battery, not a limit of the band. Alerts wait '
            'for room; a gesture without room is not acted on.',
            style: F.over.copyWith(color: p.ink3)),
        Slider(
          min: kBandCommandLimitMin.toDouble(),
          max: kBandCommandLimitMax.toDouble(),
          divisions: kBandCommandLimitMax - kBandCommandLimitMin,
          value: limit
              .clamp(kBandCommandLimitMin, kBandCommandLimitMax)
              .toDouble(),
          label: '$limit',
          onChanged: onChanged == null ? null : (v) => onChanged!(v.round()),
        ),
      ]),
    );
  }
}

// ══════════════════ NOTIFICATIONS ══════════════════
//
// There are exactly three things this app may put in your notification shade:
// the alarm, the day's aggregated exception, and the weekly lookback when the
// week contained something. The app used to be able to emit around twenty-two
// kinds — hydration slots, step goals, posture nudges, AI briefings — and none
// of them had a switch anywhere in the app, so the only way to stop any of it
// was the OS. A notification the user cannot turn off is a bug, which makes
// this screen part of the fix rather than a nicety on top of it.
//
// The alarm is deliberately not switchable here: its off switch is cancelling
// the alarm, and burying a second one in settings is how an alarm silently
// fails to wake someone.
//
// The water reminder is on this screen and IS a shade entry — a strap buzz and
// a phone notification at the same minute, because a buzz alone needs a live
// link and a live isolate and so is not a reminder. It reminds you to LOG a
// drink — the app measures no hydration and this screen may never imply it
// does. See MT-14 in IDEAS.md.

class NotificationSettings extends StatefulWidget {
  const NotificationSettings({super.key});

  @override
  State<NotificationSettings> createState() => _NotificationSettingsState();
}

class _NotificationSettingsState extends State<NotificationSettings> {
  NotificationPrefs? _prefs;
  bool _granted = false;

  // The stored patterns, to name what each alert plays.
  List<SavedHapticPattern> _patterns = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await NotificationPrefs.load();
    final granted = await NotificationService.instance.hasPermission();
    List<SavedHapticPattern> patterns = const [];
    try {
      patterns = (await SettingsRepository.instance.patterns()).list;
    } catch (_) {
      // Unnamed rows say "Custom"; the alerts still work.
    }
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _granted = granted;
      _patterns = patterns;
    });
  }

  Future<void> _apply(NotificationPrefs next) async {
    setState(() => _prefs = next);
    await SettingsRepository.instance.update(
      (d) => d.alerts = next,
      sections: {SettingsSection.alerts},
    );
    // Re-run the scheduler so a switch that was just turned off actually
    // cancels what it was standing for, rather than taking effect at some
    // later resume.
    //
    // Through AppState, not straight at the NotificationCenter: the medication
    // slots need the med schedule and the check-in needs today's journal, and
    // only AppState can read either. Calling the centre directly cancels what
    // the switch turned off and arms nothing back, so meds stayed silent until
    // the next foreground pass.
    if (mounted) await context.read<AppState>().refreshAiReminders();
    // the water buzz is an in-memory timer, not an OS slot — re-arm it here or
    // the switch only takes effect at the next launch.
    if (mounted) await context.read<AppState>().armWaterReminder(next);
    // the low-battery threshold is restored once per process — push the new
    // value into the alert pipeline or it applies only after a restart.
    if (mounted) {
      await context.read<AppState>().refreshBatteryThreshold(next);
    }
  }

  /// The one contextual moment left where prompting is honest: the user is
  /// standing in the notifications screen, having just asked for one.
  Future<void> _requestPermission() async {
    final ok = await NotificationService.instance.ensurePermission();
    if (mounted) setState(() => _granted = ok);
  }

  @override
  Widget build(BuildContext c) {
    final p = _prefs;
    final app = c.watch<AppState>();
    return NotificationSettingsView(
      prefs: p ?? const NotificationPrefs(),
      loaded: p != null,
      granted: _granted,
      onChanged: _apply,
      onRequestPermission: _requestPermission,
      onBuzzPattern: _pickPattern,
      patternNameFor: (id) => slotPatternLabel(
        alertSystemKey(id),
        patterns: _patterns,
        alerts: p ?? const NotificationPrefs(),
        channels: const {},
        cueAssignments: const {},
      ),
      onOpenHaptics: () => goto(c, const HapticsSettings()),
      zoneAlertZone: app.zoneAlertTargetZone,
      onCycleZoneAlertZone: () => app.setZoneAlertTargetZone(
          app.zoneAlertTargetZone >= 5 ? 1 : app.zoneAlertTargetZone + 1),
      onOpenZones: () => goto(c, const ZonesDetail()),
    );
  }

  /// The picker first: Default, the stored patterns, a new tap take, or
  /// notes. A stored pattern is saved into the rule as a snapshot of itself.
  void _pickPattern(String id) {
    final p = _prefs;
    if (p == null) return;
    final app = context.read<AppState>();
    final caps = context.capsRead;
    SettingsRepository.instance.patterns().then((store) {
      if (!mounted) return;
      setState(() => _patterns = store.list);
      showPatternPicker(
        context,
        patterns: store.list,
        current: p.buzzSequenceFor(id),
        defaultSequence: store.bySystemKey('alert.$id')?.sequence,
        bandConnected: caps.has(Feature.bandBuzz),
        onPlay: app.previewBuzzSequence,
        // The band's measured vocabulary (an MG), none on a 4.0.
        profile: caps.hapticProfile,
        onSaveNew: saveNewPattern,
        // Default: no sequence in the rule, so it takes the registry default.
        onDefault: () {
          final cur = _prefs;
          if (!mounted || cur == null) return;
          _apply(cur.withAlertRule(
              {...cur.alertRule(id).toJson()}..remove('buzzSequence')));
        },
        onChoose: (s) {
          final cur = _prefs;
          if (!mounted || cur == null) return;
          _apply(cur.withAlertRule(
              {...cur.alertRule(id).toJson(), 'buzzSequence': s.toJson()}));
        },
      );
    });
  }
}

/// One alert: its name, a single destination picker, and what that choice needs
/// in order to run. A destination this alert cannot honour is shown disabled.
class _AlertRow extends StatelessWidget {
  const _AlertRow(this.icon, this.color, this.title, this.sub, this.rule,
      this.onMask, {this.sequence, this.patternName, this.onBuzzPattern});
  final IconData icon;
  final Color color;
  final String title, sub;
  final AlertRule rule;
  final ValueChanged<int> onMask;

  /// What this alert buzzes the band with, and the opener for the sheet that
  /// changes it. Null [sequence] means the alert cannot reach the band.
  final BuzzSequence? sequence;

  /// The name of the pattern behind [sequence].
  final String? patternName;
  final VoidCallback? onBuzzPattern;

  static const _options = [
    (0, 'Off'),
    (AlertRule.phone, 'Phone'),
    (AlertRule.band, 'Band'),
    (AlertRule.phone | AlertRule.band, 'Phone + Band'),
  ];

  bool _supported(int mask) => [
        if (mask & AlertRule.phone != 0) 'phone',
        if (mask & AlertRule.band != 0) 'band',
      ].every(
          (t) => AlertCapabilityRegistry.destinationSupportReason(rule, t) == null);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final mask = rule.enabled ? rule.destinations : 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SetRow(icon, color, title, sub: sub, chevron: false),
      Wrap(spacing: S.x2, children: [
        for (final (m, label) in _options)
          Pressable(
            onTap: _supported(m) ? () => onMask(m) : null,
            semanticLabel:
                '$label${m == mask ? ', selected' : ''}${_supported(m) ? '' : ', unavailable'}',
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
              decoration: BoxDecoration(
                color: m == mask ? p.wash(C.blue) : null,
                borderRadius: R.rSm,
                border:
                    Border.all(color: m == mask ? p.on(C.blue) : p.line),
              ),
              child: Text(label,
                  style: F.cap.copyWith(
                      color: m == mask
                          ? p.on(C.blue)
                          : _supported(m)
                              ? p.ink
                              : p.ink3,
                      fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
      // Always drawn ("Off" when off) and reserved at three lines, the most a
      // phone + band summary takes at the default width, so switching an alert
      // on does not push every section header below it down.
      Padding(
        padding: const EdgeInsets.only(top: S.x1),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minHeight: 3 *
                  MediaQuery.textScalerOf(c).scale(
                      (F.over.fontSize ?? 12) * (F.over.height ?? 1.3))),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(AlertCapabilityRegistry.summary(rule),
                style: F.over.copyWith(color: p.ink3)),
          ),
        ),
      ),
      // Present for every alert that can reach the band, usable only while
      // Band is one of its destinations.
      if (sequence != null)
        BuzzPatternRow(
          key: ValueKey('buzz-pattern:${rule.id}'),
          sequence: sequence!,
          patternName: patternName,
          enabled: mask & AlertRule.band != 0 && onBuzzPattern != null,
          onTap: onBuzzPattern,
        ),
      const SizedBox(height: S.x3),
    ]);
  }
}

class NotificationSettingsView extends StatelessWidget {
  final NotificationPrefs prefs;
  final bool loaded, granted;

  /// No longer drawn: the relay's one entrance is Settings > Alerts > App
  /// notifications on the band. Kept so existing construction sites
  /// compile.
  final bool relaySupported;

  final Future<void> Function(NotificationPrefs next)? onChanged;
  final VoidCallback? onRequestPermission;

  /// Opens the buzz-pattern sheet for one alert (by rule id).
  final void Function(String ruleId)? onBuzzPattern;

  /// The name of the pattern an alert plays (by rule id), shown on its buzz
  /// pattern row. Null: the rows say "Custom".
  final String Function(String ruleId)? patternNameFor;

  /// Opens the Haptics screen, where the patterns are made and every slot is
  /// listed.
  final VoidCallback? onOpenHaptics;

  /// The HR zone alert's own settings: the zone (1..5) it watches, the step
  /// to the next one, and the door to the zone screen.
  final int zoneAlertZone;
  final VoidCallback? onCycleZoneAlertZone, onOpenZones;

  const NotificationSettingsView({
    super.key,
    this.prefs = const NotificationPrefs(),
    this.loaded = true,
    this.granted = true,
    this.relaySupported = false,
    this.onChanged,
    this.onRequestPermission,
    this.onBuzzPattern,
    this.patternNameFor,
    this.onOpenHaptics,
    this.zoneAlertZone = 3,
    this.onCycleZoneAlertZone,
    this.onOpenZones,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final on = l?.stateOn ?? 'On';
    final off = l?.stateOff ?? 'Off';
    void set(NotificationPrefs next) => onChanged?.call(next);
    Widget row(String id, IconData icon, Color color, String title, String sub) {
      final rule = prefs.alertRule(id);
      return _AlertRow(icon, color, title, sub, rule,
          (mask) => set(prefs.withAlertRule(
              {...rule.toJson(), 'enabled': mask != 0, 'destinations': mask})),
          sequence: AlertCapabilityRegistry.destinationSupportReason(
                      rule, 'band') ==
                  null
              ? prefs.buzzSequenceFor(id)
              : null,
          patternName: patternNameFor?.call(id),
          onBuzzPattern: () => onBuzzPattern?.call(id));
    }

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsNotificationsNavTitle ?? 'Notifications',
                sub: l?.settingsNotificationsNavSub ??
                    'ALERT TYPES'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (!granted)
                  StatusCard(
                    l?.settingsNotificationsOffSystemTitle ??
                        'Notifications are off at the system level',
                    l?.settingsNotificationsOffSystemBody ??
                        'No alert below is delivered until you allow notifications in system settings.',
                    fix: l?.settingsTurnThemOn ?? 'Turn them on',
                    icon: LucideIcons.bellOff,
                    onFix: onRequestPermission,
                  ),
                if (loaded) ...[
                  // Stable groups: each stays in place whether or not anything in
                  // it is on, and opens only through its own header. Every alert
                  // has one destination picker and says what it needs to run.
                  SettingsAccordion(
                      'Alarms & Wake',
                      id: 'notifications_alarms_wake',
                      initiallyExpanded: true,
                      children: [
                        // On by default: this exists to catch a wake alarm that
                        // silently isn't going to fire.
                        row('alarmLatchFailed', LucideIcons.alarmClock, C.red,
                            l?.settingsAlarmLatchFailedRowTitle ??
                                'Alarm not confirmed',
                            l?.settingsAlarmLatchFailedRowSub ??
                                'Warn when the band never confirms an alarm '
                                    'this app just armed'),
                        // Also on by default; silent whenever an alarm IS armed.
                        row('alarmNightCheck', LucideIcons.moon, C.red,
                            l?.settingsAlarmNightCheckRowTitle ??
                                'No-alarm check-in',
                            l?.settingsAlarmNightCheckRowSub ??
                                'A 7pm reminder on any night with no wake alarm '
                                'armed. Sends nothing otherwise'),
                      ]),
                  SettingsAccordion('Health',
                      id: 'notifications_health',
                      children: [
                    row('health', LucideIcons.heartPulse, C.red,
                        l?.settingsHealthExceptionsRowTitle ??
                            'Health exceptions',
                        l?.settingsHealthExceptionsRowSub ??
                            'At most one a day, and only when a metric moves '
                            'outside your own baseline'),
                    row('recovery', LucideIcons.activity, C.green,
                        l?.settingsRecoveryReadyRowTitle ?? 'Recovery ready',
                        l?.settingsRecoveryReadyRowSub ??
                            'One notification when your morning recovery score is ready'),
                  ]),
                  SettingsAccordion(
                      'Activity',
                      id: 'notifications_activity',
                      initiallyExpanded: true,
                      children: [
                        // The auto-detector's off switch: it stops the prompt,
                        // not the detection itself.
                        row('autoDetect', LucideIcons.radar, C.green,
                            l?.settingsDetectedWorkoutsRowTitle ??
                                'Detected workouts',
                            l?.settingsDetectedWorkoutsRowSub ??
                                'Asks about efforts the band detected that you did not start. '
                                'Off hides the prompt and the review cards. '
                                'The band keeps measuring either way'),
                        row('movement', LucideIcons.footprints, C.orange,
                            l?.settingsMovementNudgeRowTitle ?? 'Movement nudge',
                            'Nudges you after two hours with no movement '
                            'or 90 minutes in a desk '
                            'posture'),
                        row('stepGoal', LucideIcons.trophy, C.orange,
                            l?.settingsStepGoalAlertsRowTitle ??
                                'Step goal alerts',
                            l?.settingsStepGoalAlertsRowSub ??
                                'Notifies you once when today\'s steps '
                                'reach your goal'),
                        // A live-workout alert: the band buzzes when the heart
                        // rate crosses into or out of the target zone. The
                        // zone row is always drawn, dimmed while it is off.
                        row('zone', LucideIcons.heartPulse, C.red,
                            l?.settingsZoneAlertRowTitle ?? 'HR zone alert',
                            l?.settingsZoneAlertRowSub ??
                                'Buzz when your heart rate crosses into or out '
                                    'of the target zone during a live workout'),
                        SetRow(LucideIcons.target, C.red,
                            l?.settingsZoneAlertTargetRowTitle ?? 'Target zone',
                            enabled: prefs.alertRule('zone').enabled,
                            sub: prefs.alertRule('zone').enabled
                                ? 'The zone to stay in'
                                : 'Turn on HR zone alert first',
                            value: l?.settingsZoneAlertTargetRowValue(
                                    zoneAlertZone) ??
                                'Zone $zoneAlertZone',
                            chevron: false,
                            onTap: onCycleZoneAlertZone),
                        SetRow(LucideIcons.activity, C.red, 'Zone view',
                            key: const ValueKey('zone-alert-open-zones'),
                            sub: 'Your heart-rate zones and their limits',
                            onTap: onOpenZones ??
                                () => goto(c, const ZonesDetail())),
                      ]),
                  SettingsAccordion(
                      'Reminders',
                      id: 'notifications_reminders',
                      initiallyExpanded: true,
                      children: [
                        row('reminders', LucideIcons.calendarDays, C.purple,
                            l?.settingsWeeklyLookbackRowTitle ??
                                'Weekly lookback',
                            l?.settingsWeeklyLookbackRowSub ??
                                'Sunday evening, only for a week '
                                'with a finding'),
                        // The notification names no drug: it lands on a lock
                        // screen in front of whoever is in the room.
                        row('meds', LucideIcons.pill, C.blue,
                            l?.settingsMedicationRemindersRowTitle ??
                                'Medication reminders',
                            'One alert per scheduled dose, at the times you '
                            'entered. No alert for a dose already '
                            'marked taken or skipped'),
                        row('checkIn', LucideIcons.notebookPen, C.purple,
                            l?.settingsDailyCheckInRowTitle ?? 'Daily check-in',
                            l?.settingsDailyCheckInRowSub ??
                                'One evening prompt to log your '
                                'mood, energy and stress. Skipped if the day '
                                'already has a rating'),
                        // A prompt to log, not a reading: the app measures no
                        // hydration and this may never imply it does.
                        row('water', LucideIcons.glassWater, C.teal,
                            l?.settingsWaterReminderRowTitle ?? 'Water reminder',
                            'Reminds you during your waking hours to log a '
                            'drink'),
                        // Always drawn; dimmed while the reminder is off.
                        SetRow(LucideIcons.timer, C.teal,
                              l?.settingsRemindMeEveryRowTitle ??
                                  'Remind me every',
                              enabled: prefs.waterEnabled,
                              sub: prefs.waterEnabled
                                  ? 'How often the reminder repeats'
                                  : 'Turn on the water reminder first',
                              value: _everyLabel(prefs.waterIntervalMin),
                              chevron: false,
                              onTap: () => set(prefs.copyWith(
                                  waterIntervalMin:
                                      _nextEvery(prefs.waterIntervalMin)))),
                        // Silent until the Sleep Coach has LEARNED a bedtime.
                        row('windDown', LucideIcons.moonStar, C.indigo,
                            l?.settingsWindDownRowTitle ?? 'Wind-down',
                            l?.settingsWindDownRowSub ??
                                'Notifies you about 45 minutes before the bedtime '
                                'learned from your own nights, outside '
                                'your quiet hours. Appears after about a '
                                'week of wear'),
                      ]),
                  SettingsAccordion('Device',
                      id: 'notifications_device',
                      children: [
                    row('device', LucideIcons.watch, C.orange,
                        l?.settingsBandAlertsRowTitle ?? 'Band battery',
                        l?.settingsBandAlertsRowSub ??
                            'Low battery, charging status, and a band that stops reporting'),
                    SetRow(LucideIcons.batteryLow, C.orange,
                          l?.settingsAlertMeAtRowTitle ?? 'Alert me at',
                          enabled: prefs.deviceEnabled,
                          sub: !prefs.deviceEnabled
                              ? 'Turn on Band battery first'
                              : l?.settingsAlertMeAtRowSub ??
                                  'Warns when the band\'s charge falls below this '
                                  'level',
                          value: '${prefs.batteryAlertPct}%',
                          chevron: false,
                          onTap: () => set(prefs.copyWith(
                              batteryAlertPct:
                                  _nextBatteryPct(prefs.batteryAlertPct)))),
                  ]),
                  SettingsAccordion(l?.settingsGroupQuietHours ?? 'Quiet hours',
                      id: 'notifications_quiet_hours',
                      children: [
                    SetRow(LucideIcons.moon, C.indigo,
                        l?.settingsQuietHoursRowTitle ?? 'Quiet hours',
                        sub: l?.settingsQuietHoursRowSub ??
                            'Nothing buzzes inside this window',
                        value: prefs.quietEnabled ? on : off,
                        chevron: false,
                        onTap: () => set(
                            prefs.copyWith(quietEnabled: !prefs.quietEnabled))),
                    SetRow(LucideIcons.sunset, C.blue,
                        l?.settingsQuietHoursStartsRowTitle ?? 'Starts',
                        value: hhmm(prefs.quietStartMin),
                        chevron: false,
                        onTap: () async {
                          final v = await pickMinute(c, prefs.quietStartMin);
                          if (v != null) set(prefs.copyWith(quietStartMin: v));
                        }),
                    SetRow(LucideIcons.sunrise, C.yellow,
                        l?.settingsQuietHoursEndsRowTitle ?? 'Ends',
                        value: hhmm(prefs.quietEndMin),
                        chevron: false,
                        onTap: () async {
                          final v = await pickMinute(c, prefs.quietEndMin);
                          if (v != null) set(prefs.copyWith(quietEndMin: v));
                        }),
                    SetRow(LucideIcons.triangleAlert, C.red,
                        l?.settingsHealthExceptionsBreakThroughRowTitle ??
                            'Health exceptions break through',
                        value: prefs.criticalOverridesQuiet ? on : off,
                        chevron: false,
                        onTap: () => set(prefs.copyWith(
                            criticalOverridesQuiet:
                                !prefs.criticalOverridesQuiet))),
                  ]),
                  // Same gap above as the accordions around it.
                  Padding(
                    padding: const EdgeInsets.only(top: S.x3),
                    child: Surface(
                      pad: const EdgeInsets.symmetric(horizontal: S.x4),
                      child: SetRow(
                        LucideIcons.vibrate,
                        C.purple,
                        'Haptics',
                        key: const ValueKey('alerts-open-haptics'),
                        sub: 'The pattern each alert plays, and your own',
                        onTap: onOpenHaptics,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: S.x3),
                StatusCard(
                  l?.settingsAlarmNotOnListTitle ??
                      'The alarm is not on this list',
                  l?.settingsAlarmNotOnListBody ??
                      'Cancel it on the Alarm screen instead.',
                  icon: LucideIcons.alarmClock,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// The water intervals on offer, all inside
  /// [NotificationPrefs.waterIntervalMinAllowed]..[NotificationPrefs.waterIntervalMaxAllowed].
  /// None of them is "recommended" — we have no basis for one.
  static const waterEvery = [
    (30, '30m'),
    (60, '1h'),
    (90, '90m'),
    (120, '2h'),
    (180, '3h'),
    (240, '4h'),
  ];

  static String _everyLabel(int min) =>
      waterEvery.firstWhere((e) => e.$1 == min, orElse: () => (min, '${min}m'))
          .$2;

  /// Tapped through in place, like Units and Appearance. An unknown stored
  /// value (an older build, a hand-edited pref) lands on the first choice.
  static int _nextEvery(int min) {
    final i = waterEvery.indexWhere((e) => e.$1 == min);
    return waterEvery[(i + 1) % waterEvery.length].$1;
  }

  /// Low-battery alert thresholds, tapped through in place like [waterEvery].
  /// Bounds match NotificationPrefs.batteryPctMin/Max, so every choice here is
  /// one the pref will store unclamped.
  static const batteryChoices = [10, 15, 20, 25, 30, 40];

  static int _nextBatteryPct(int pct) {
    final i = batteryChoices.indexOf(pct);
    return batteryChoices[(i + 1) % batteryChoices.length];
  }

  static String hhmm(int minuteOfDay) {
    final m = minuteOfDay % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  static Future<int?> pickMinute(BuildContext c, int current) async {
    final picked = await showTimePicker(
      context: c,
      initialTime: TimeOfDay(hour: (current ~/ 60) % 24, minute: current % 60),
    );
    return picked == null ? null : picked.hour * 60 + picked.minute;
  }
}

// ══════════════════ CALCULATIONS ══════════════════

/// The three Calculations modes as the settings row and the picker word them.
/// No numbers: nothing here promises a time or a battery saving.
const calcPowerLabels = {
  CalcPowerMode.maxBattery: 'Maximum battery',
  CalcPowerMode.balanced: 'Balanced',
  CalcPowerMode.eager: 'Eager',
};

const _calcPowerSentences = {
  CalcPowerMode.maxBattery:
      'Calculates after a sync or when you ask, one day at a time, and '
          'prepares nothing in the background.',
  CalcPowerMode.balanced:
      'Also prepares your screens while the app is idle or charging; your '
          "phone's battery saver pauses that.",
  CalcPowerMode.eager:
      'On a charger it calculates every day and screen it can, even when '
          "your phone's battery saver is on.",
};

/// A sheet with the three modes, each with one plain sentence. Tapping one
/// closes it with that mode; dismissing returns null.
Future<CalcPowerMode?> pickCalcPowerMode(BuildContext c, CalcPowerMode current) {
  final p = P.of(c);
  return showModalBottomSheet<CalcPowerMode>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in CalcPowerMode.values)
              ListTile(
                key: ValueKey('calc-power-option-${m.name}'),
                title: Text(calcPowerLabels[m]!,
                    style: F.body.copyWith(color: p.ink)),
                subtitle: Text(_calcPowerSentences[m]!,
                    style: F.cap.copyWith(color: p.ink3)),
                trailing: m == current
                    ? Icon(LucideIcons.check, size: 18, color: p.on(C.blue))
                    : null,
                onTap: () => Navigator.of(sheet).pop(m),
              ),
          ],
        ),
      ),
    ),
  );
}

// ══════════════════ EDIT PROFILE ══════════════════

class EditProfile extends StatelessWidget {
  const EditProfile({super.key});

  @override
  Widget build(BuildContext c) {
    final app = c.read<AppState>();
    return EditProfileView(
      initial: app.user ?? const {},
      // The app SHOWED lb and EDITED kg: Health converted on the way out, this
      // form did not convert on the way in, so typing back the 172 lb the app
      // had just printed stored 172 kg.
      units: c.watch<UnitsController>(),
      // The read lives on the form it fills. It used to be three taps away on
      // a settings screen, which is a long way to go to keep a weight current
      // — and the weight is the one the calorie and BMR estimates read.
      //
      // The merge policy (weight and height win, age and sex only fill a gap)
      // stays in `mergeHealthProfile` and is not re-decided here. The fields
      // come back so the form shows what arrived rather than claiming it.
      onImport: () async {
        final importer = HealthProfileImporter();
        final l = AppLocalizations.of(c);
        // Asked HERE, on the tap, and for these four types only. Nothing at
        // launch and nothing in onboarding: a permission sheet for data the
        // user has not asked us to read is how the whole set gets denied at
        // once.
        if (!await importer.requestPermission()) {
          return (
            l?.settingsImportNoPermission(storeName) ??
                '$storeName did not grant those fields. Nothing was read.',
            true,
            null,
          );
        }
        final snap = await importer.read();
        if (snap.isEmpty) {
          return (
            isAppleHealth
                ? (l?.settingsImportEmptyWithBirthday(storeName) ??
                    '$storeName has no height, weight, birthday '
                    'or sex on record for you. Enter them here.')
                : (l?.settingsImportEmpty(storeName) ??
                    '$storeName has no height, weight'
                    ' or sex on record for you. Enter them here.'),
            false,
            null,
          );
        }
        await markImported(HealthImport.profile);
        if (!c.mounted) return ('', false, null);
        final app = c.read<AppState>();
        final changes = healthProfileChanges(app.user, snap);
        final merged = mergeHealthProfile(app.user, snap);
        // Nothing to write is not a write of the same thing: `updateProfile`
        // notifies every listener and re-scores the day.
        if (changes.isEmpty) {
          return (
            l?.settingsImportNoChange(snap.found.join(', ')) ??
                'Read ${snap.found.join(', ')}. Your profile already matches, so nothing changed.',
            false,
            merged,
          );
        }
        await app.updateProfile(merged);
        return (
          l?.settingsImportUpdated(changes.join(', '), storeName) ??
              'Updated ${changes.join(', ')} from $storeName.',
          false,
          merged
        );
      },
      onSave: (fields) async {
        // A field the user CLEARED must be removed, not merged over — the
        // profile map is a merge, so writing only what is present would keep
        // a stale value alive and score the day against a body that is no
        // longer described.
        await app.updateProfile({
          for (final k in const [
            'name',
            'sex',
            'age',
            'height_cm',
            'weight_kg',
          ])
            k: fields[k],
        });
        if (c.mounted) Navigator.of(c).maybePop();
      },
    );
  }
}

class EditProfileView extends StatefulWidget {
  final Map<String, dynamic> initial;
  final Future<void> Function(Map<String, dynamic> fields) onSave;

  /// Display units for the height and weight fields. Null is metric, which is
  /// also what the storage is — the conversion only exists for imperial.
  final UnitsController? units;

  /// Read these fields from the phone's health store.
  ///
  /// Returns the line to show, whether it failed, and the profile as it now
  /// stands so the form can display what arrived. Null means no button — the
  /// gallery and the golden sweep get the form without a control that would
  /// raise a real health-store prompt from a screenshot.
  final Future<(String note, bool failed, Map<String, dynamic>? fields)>
          Function()?
      onImport;

  const EditProfileView(
      {super.key,
      required this.onSave,
      this.initial = const {},
      this.units,
      this.onImport});

  @override
  State<EditProfileView> createState() => _EditProfileViewState();
}

class _EditProfileViewState extends State<EditProfileView> {
  late final UnitsController _u =
      widget.units ?? UnitsController.seed(UnitSystem.metric);
  late final _name =
      TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final _age =
      TextEditingController(text: _s(widget.initial['age']));
  late final _height =
      TextEditingController(text: _u.heightField(widget.initial['height_cm'] as num?));
  late final _weight =
      TextEditingController(text: _u.weightField(widget.initial['weight_kg'] as num?));
  late String? _sex = (widget.initial['sex'] as String?)?.toLowerCase();

  /// When the store last gave us something. Null is "never", which is also
  /// what an unreadable preference reads as — the first-run word on the button
  /// is the safe one either way.
  DateTime? _lastImport;
  bool _importing = false;
  String? _importNote;
  bool _importFailed = false;

  static String _s(Object? v) => v == null ? '' : '$v';

  @override
  void initState() {
    super.initState();
    if (widget.onImport == null) return;
    lastImportAt(HealthImport.profile).then((at) {
      if (mounted) setState(() => _lastImport = at);
    });
  }

  /// Read, then show what arrived in the fields it fills.
  ///
  /// The controllers are rewritten rather than the screen rebuilt from
  /// `AppState`: this form owns its text while it is open, and a value that
  /// changed underneath it without the field moving is a value the user never
  /// sees.
  Future<void> _import() async {
    final job = widget.onImport;
    if (job == null || _importing) return;
    setState(() {
      _importing = true;
      _importNote = null;
    });
    try {
      final (note, failed, fields) = await job();
      if (!mounted) return;
      if (fields != null) {
        _age.text = _s(fields['age']);
        _height.text = _u.heightField(fields['height_cm'] as num?);
        _weight.text = _u.weightField(fields['weight_kg'] as num?);
        _sex = (fields['sex'] as String?)?.toLowerCase() ?? _sex;
      }
      setState(() {
        _importNote = note;
        _importFailed = failed;
        if (!failed && fields != null) _lastImport = DateTime.now();
      });
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        setState(() {
          _importNote = l?.settingsImportFailed('$e') ?? 'Failed: $e';
          _importFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  /// A field that cannot be read is NOT a cleared field.
  ///
  /// Every key here is written unconditionally, precisely so a cleared one is
  /// removed rather than merged over — which meant a typo ("78 kg", "78,5")
  /// parsed to null and wiped the stored weight while the screen popped as if
  /// it had saved. Blank still clears; a typo now stops the save and says so.
  void _save() {
    final l = AppLocalizations.of(context);
    final age = Typed.of(_age.text);
    final height = Typed.of(_height.text);
    final weight = Typed.of(_weight.text);
    final bad = [
      if (age.bad) (l?.settingsAgeFieldLabel ?? 'Age'),
      if (height.bad) _u.heightLabel,
      if (weight.bad) _u.weightLabel,
    ];
    if (bad.isNotEmpty) {
      sayUnreadable(context, bad);
      return;
    }
    widget.onSave({
      'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
      'sex': _sex,
      'age': age.value?.round(),
      // Typed in the units on the label, stored in metric.
      'height_cm': height.value == null ? null : _u.heightToCm(_height.text),
      'weight_kg': weight.value == null ? null : _u.weightToKg(_weight.text),
    });
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsEditProfileNavTitle ?? 'Edit profile',
                trailing: Pressable(
                  semanticLabel: l?.actionSave ?? 'Save',
                  onTap: _save,
                  child: Text(l?.actionSave ?? 'Save',
                      style: F.body.copyWith(
                          color: p.on(C.green), fontWeight: FontWeight.w600)),
                )),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                SettingsAccordion('About you',
                    id: 'edit_profile_about_you',
                    children: [
                  _text(c, _name, l?.settingsNameFieldLabel ?? 'NAME',
                      TextInputType.name),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l?.settingsSexFieldLabel ?? 'SEX',
                              style: F.over.copyWith(color: p.ink3)),
                          const SizedBox(height: S.x2),
                          Wrap(spacing: S.x2, runSpacing: S.x2, children: [
                            for (final (key, label) in [
                              ('m', l?.settingsSexMale ?? 'Male'),
                              ('f', l?.settingsSexFemale ?? 'Female'),
                              (
                                'other',
                                l?.settingsSexPreferNotToSay ?? 'Prefer not to say'
                              ),
                            ])
                              Pressable(
                                onTap: () => setState(() => _sex = key),
                                semanticLabel: label,
                                child: Container(
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: S.x4, vertical: S.x2),
                                  decoration: BoxDecoration(
                                    color:
                                        _sex == key ? p.wash(C.green) : p.card,
                                    borderRadius: R.rPill,
                                    border: Border.all(
                                        color: _sex == key
                                            ? p.on(C.green)
                                            : p.line),
                                  ),
                                  child: Text(label,
                                      style: F.cap.copyWith(
                                          color: _sex == key
                                              ? p.on(C.green)
                                              : p.ink2)),
                                ),
                              ),
                          ]),
                        ]),
                  ),
                  _text(c, _age, l?.settingsAgeYearsFieldLabel ?? 'AGE (YEARS)',
                      TextInputType.number),
                ]),
                SettingsAccordion('Body', id: 'edit_profile_body', children: [
                  _text(c, _height, _u.heightLabel.toUpperCase(),
                      TextInputType.number),
                  _text(c, _weight, _u.weightLabel.toUpperCase(),
                      TextInputType.number),
                ]),
                ..._importBlock(p, c),
                const SizedBox(height: S.x6),
                StatusCard(
                  l?.settingsFourFieldsTitle ?? 'These four fields affect your metrics',
                  l?.settingsFourFieldsBody ??
                      'They feed heart-rate zones, calorie estimates and training '
                          'load. Clear one and only the metrics that need it stay '
                          'unavailable.',
                  icon: LucideIcons.info,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// The health-store read, on the form it fills. Empty when the caller passed
  /// no [EditProfileView.onImport] — the gallery and the golden sweep must not
  /// carry a control that raises a real permission sheet.
  List<Widget> _importBlock(P p, BuildContext c) {
    if (widget.onImport == null) return const [];
    final l = AppLocalizations.of(c);
    return [
      SettingsAccordion('From $storeName',
          id: 'edit_profile_import',
          children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            isAppleHealth
                ? (l?.settingsImportBlockAppleHealth(storeName) ??
                    'Height, weight, birthday and sex from '
                    '$storeName. Height and weight are overwritten each time. '
                    'Birthday and sex only fill empty fields, '
                    'because a value already here was your choice.')
                : (l?.settingsImportBlockOther(storeName) ??
                    'Height and weight from $storeName. It has no '
                    'birthday or sex to read, so set those '
                    'two above.'),
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
          const SizedBox(height: S.x4),
          BigButton(
            importLabel(_lastImport),
            icon: LucideIcons.scale,
            color: C.purple,
            soft: true,
            onTap: _importing ? null : _import,
          ),
          if (_importNote != null && _importNote!.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            Text(
              _importNote!,
              style: F.cap.copyWith(
                  color: _importFailed ? p.on(C.red) : p.ink2, height: 1.5),
            ),
          ],
        ]),
        ),
      ]),
    ];
  }

  Widget _text(BuildContext c, TextEditingController ctl, String label,
      TextInputType kind) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child:
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: F.over.copyWith(color: p.ink3)),
      TextField(
        controller: ctl,
        keyboardType: kind,
        style: F.head.copyWith(color: p.ink),
        decoration: InputDecoration(
          hintText: l?.settingsNotSetHint ?? 'Not set',
          hintStyle: F.head.copyWith(color: p.ink3),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: S.x3),
          enabledBorder:
              UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
          focusedBorder:
              UnderlineInputBorder(borderSide: BorderSide(color: p.on(C.green))),
        ),
      ),
    ]));
  }
}

// ══════════════════ AUTOMATION ══════════════════
//
// THE TWO PLATFORMS ARE NOT SYMMETRIC AND THIS SCREEN SAYS SO.
//
// Android gets real outbound event triggers: the app broadcasts an intent an
// automation app can start a profile on. iOS does NOT — there is no public
// mechanism for a Shortcuts personal automation to trigger on an arbitrary
// app-donated intent; that trigger list is a fixed system set, and
// `donate`/INInteraction buys Siri suggestions and discoverability, not an
// event trigger. So the iOS half of this screen names what iOS can do (invoke
// the app) and what it cannot (be invoked by it), rather than describing the
// Android feature in language vague enough to read as parity.
//
// And nothing that leaves here is a measurement. A Shortcut that receives
// `readiness=0` has recreated the fabricated-number problem outside the app,
// where there is no tier and no note to explain it — so the one event that
// ships carries facts about the SYNC and no metric at all.

class AutomationSettings extends StatefulWidget {
  const AutomationSettings({super.key});

  @override
  State<AutomationSettings> createState() => _AutomationSettingsState();
}

class _AutomationSettingsState extends State<AutomationSettings> {
  String? _token;
  bool _copied = false;
  bool _taskerOn = Prefs.taskerConnectionOn;

  @override
  void initState() {
    super.initState();
    TaskerBridge.authToken().then((t) {
      if (mounted) setState(() => _token = t);
    });
  }

  Future<void> _copy() async {
    final t = _token;
    if (t == null) return;
    await Clipboard.setData(ClipboardData(text: t));
    if (mounted) setState(() => _copied = true);
  }

  void _setTaskerOn(bool on) {
    Prefs.setBool(Prefs.taskerConnection, on);
    setState(() => _taskerOn = on);
  }

  @override
  Widget build(BuildContext c) => AutomationSettingsView(
      token: _token,
      copied: _copied,
      onCopy: _copy,
      taskerOn: _taskerOn,
      onTaskerOn: _setTaskerOn);
}

/// The Automation screen without its token fetch, so it can be pumped headless.
/// [token] is null until the bridge answers.
class AutomationSettingsView extends StatelessWidget {
  const AutomationSettingsView(
      {super.key,
      this.token,
      this.copied = false,
      this.onCopy,
      this.taskerOn = true,
      this.onTaskerOn});
  final String? token;
  final bool copied;
  final VoidCallback? onCopy;

  /// "Tasker connection" (key `tasker-connection`, Android only) and its
  /// callback. Off: the Tasker rows below it are drawn but disabled and
  /// dimmed, with the hint "Turn on Tasker first".
  final bool taskerOn;
  final ValueChanged<bool>? onTaskerOn;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final android = c.caps.has(Feature.androidAutomation);
    final token = this.token;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.settingsAutomationNavTitle ?? 'Automation'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (android)
                  SettingsAccordion(
                    l?.settingsTaskerConnectionSectionTitle ?? 'Tasker',
                    id: 'automation_tasker',
                    children: [
                      SwitchRow(
                        l?.settingsTaskerConnectionTitle ?? 'Tasker connection',
                        taskerOn,
                        onTaskerOn,
                        key: const ValueKey('tasker-connection'),
                        sub: l?.settingsTaskerConnectionSub ??
                            'Lets Tasker and other automation apps buzz the '
                                'band, and lets the Broadcast to Tasker '
                                'gesture action reach them. Off, all of it '
                                'stops.',
                      ),
                    ],
                  ),
                SettingsAccordion(
                  l?.settingsSyncFinishesSectionTitle ??
                      'When a sync finishes',
                  id: 'automation_sync_finishes',
                  children: [
                    Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            android
                                ? (l?.settingsSyncFinishesAndroidBody ??
                                    'After each sync the app broadcasts an Android intent. '
                                    'Your automation app can start a profile from it. '
                                    'Filter on the action below. The intent carries how many records '
                                    'landed and when, and is sent at most once a minute.')
                                : (l?.settingsSyncFinishesIosBody ??
                                    "iOS cannot do this. A Shortcuts personal automation only triggers on Apple's own fixed list of events, and apps cannot add to it, so nothing here can start a shortcut. Android supports it."),
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                          if (android) ...[
                            const SizedBox(height: S.x3),
                            SelectableText(
                              'wtf.openstrap.openstrap_edge.SYNC_COMPLETE',
                              style: F.cap.copyWith(color: p.ink),
                            ),
                            const SizedBox(height: S.x1),
                            Text(
                                l?.settingsSyncFinishesExtras ??
                                    'Extras: records (int), at (unix seconds)',
                                style: F.over.copyWith(color: p.ink3)),
                          ],
                        ]),
                    ),
                  ],
                ),
                SettingsAccordion(
                  l?.settingsNeverSendSectionTitle ?? 'What it will never send',
                  id: 'automation_never_send',
                  children: [
                    Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Text(
                      l?.settingsNeverSendBody ??
                          'It sends no readiness, strain or sleep score on either platform. '
                          'An absent value would arrive as a bare zero, so no scores are sent. '
                          'Only facts about the sync go out, never measurements.',
                      style: F.body,
                    ),
                    ),
                  ],
                ),
                SettingsAccordion(
                  l?.settingsBuzzFromShortcutSectionTitle ??
                      'Buzzing the band from a shortcut',
                  id: 'automation_buzz_shortcut',
                  children: [
                    Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            android
                                ? (l?.settingsBuzzFromShortcutAndroidBody ??
                                    'Send wtf.openstrap.openstrap_edge.BUZZ_STRAP with this token as the string extra "token". The token stops other apps on the phone from buzzing your band.')
                                : (l?.settingsBuzzFromShortcutIosBody ??
                                    'On iOS, a shortcut you run yourself can reach the app. It cannot start itself when the band syncs.'),
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                          if (android && !taskerOn) ...[
                            const SizedBox(height: S.x2),
                            Text(l?.taskerTurnOnFirst ?? 'Turn on Tasker first',
                                style: F.over.copyWith(color: p.ink3)),
                          ],
                          if (android) ...[
                            const SizedBox(height: S.x4),
                            if (token == null)
                              Text(
                                  l?.settingsNoTokenYet ??
                                      'No token yet — reopen this screen.',
                                  style: F.cap.copyWith(color: p.ink3))
                            else ...[
                              SelectableText(token,
                                  style: F.cap.copyWith(color: p.ink)),
                              const SizedBox(height: S.x3),
                              // Tasker off: still drawn, dimmed and inert.
                              Opacity(
                                opacity: taskerOn ? 1 : kDisabledOpacity,
                                child: BigButton(
                                    copied
                                        ? (l?.settingsCopied ?? 'Copied')
                                        : (l?.settingsCopyTheToken ??
                                            'Copy the token'),
                                    icon: copied
                                        ? LucideIcons.check
                                        : LucideIcons.copy,
                                    color: C.indigo,
                                    soft: true,
                                    onTap: taskerOn ? onCopy : null),
                              ),
                            ],
                          ],
                        ]),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
