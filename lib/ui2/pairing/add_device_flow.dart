// What happens when the user taps a device found by the "Add a device" scan.
// One scan covers sensors and bands; which it is gets decided here, after the
// scan, and the user confirms before anything is saved. The pairing operation
// and the main-band flow are injected, so this runs without a radio.
import 'package:flutter/widgets.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/band_identity.dart';
import '../../ble/hrs_link.dart' show BandCandidate;
import 'pair_sheets.dart';

enum AddDeviceOutcome {
  /// The user backed out; nothing was saved.
  cancelled,

  /// Saved as a secondary sensor ("You paired a secondary sensor.").
  pairedSecondary,

  /// Saved, and not a secondary sensor (a scale, a thermometer).
  pairedOther,

  /// Handed to the main-band flow; nothing was saved here.
  openedBandFlow,

  /// Pairing failed; [AddDeviceResult.message] says why.
  failed,

  /// The main-band flow cannot open right now (iOS, no provisioned band, so
  /// the system pairing sheet would fail until a restart);
  /// [AddDeviceResult.message] is the restart guidance. Nothing was saved.
  bandFlowHeldBack,
}

typedef AddDeviceResult = ({AddDeviceOutcome outcome, String? message});

AddDeviceResult _r(AddDeviceOutcome o, [String? message]) =>
    (outcome: o, message: message);

/// Entries that cannot be paired from a list tap: the ring asks for its key on
/// its own screen, so every choice for it ends in the band flow.
const Set<String> _ownScreen = {'oura'};

/// What the "Add a device" scan listens for: every registry entry, the framed
/// WHOOP bands included, so a WHOOP that advertises only its own band service
/// still turns up and goes to the band-choice flow.
List<BandEntry> addDeviceScanEntries() => List.unmodifiable(kBandRegistry);

/// What the flow needs from the screen and the radio.
abstract interface class AddDeviceIo {
  /// Whether a main band is paired right now (read at tap time).
  bool get hasMainBand;

  /// The pairing operation for [cand] under registry [entry]; the real one is
  /// `HrsLink.pairNotifySensor`, tests pass a fake.
  Future<PairOutcome> pair(
      BandCandidate cand, BandEntry entry, PairConfirmation? confirmation);

  /// Ends this screen's own scan (awaited), so the next screen starts on a
  /// radio that is not scanning.
  Future<void> stopScan();

  /// Why the main-band flow cannot open right now, as restart guidance
  /// (`HrsLink.scanHeldBackReason`); null when it can.
  Future<String?> mainBandBlockedReason();

  /// Opens the main-band pairing for [band].
  Future<void> openBandFlow(BandEntry band);
}

class AddDeviceFlow {
  final AddDeviceIo io;
  const AddDeviceFlow(this.io);

  static BandEntry? _entry(String id) =>
      kBandRegistry.where((e) => e.id == id).firstOrNull;

  /// Capture [c]'s navigator and localizations before the first await; the
  /// sheets use it again after each one, so the caller must keep it mounted.
  Future<AddDeviceResult> onTap(BuildContext c, BandCandidate cand) async {
    final entry = _entry(cand.entryId);
    if (entry == null) return _r(AddDeviceOutcome.cancelled);
    // A band in its own right, or a sensor-looking device that is also a band.
    final band = entry.role == DeviceRole.band ? entry : cand.alsoBand?.entry;
    if (band != null) {
      final choice = await showBandFoundSheet(c,
          band: band, hasMainBand: io.hasMainBand);
      if (choice == null) return _r(AddDeviceOutcome.cancelled);
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      if (choice == BandSheetChoice.asBand || _ownScreen.contains(entry.id)) {
        return _handoff(band);
      }
      // A WHOOP kept as a secondary sensor is paired as a heart-rate sensor.
      return _pair(c, cand, entry.isFramed ? kBleHrs : entry,
          confirmation: PairConfirmation(
              remoteId: cand.device.remoteId.str, bandEntryId: band.id));
    }
    if (!await confirmBrowse(c, entry) || !c.mounted) {
      return _r(AddDeviceOutcome.cancelled);
    }
    return _pair(c, cand, entry);
  }

  /// The confirmation owed before pairing [entry] that the user picked from a
  /// list rather than found live: a workout sensor and no band asks before
  /// being saved as all there is. False when the user went back. A device
  /// paired as its own entry (Colmi as Colmi) needs none.
  Future<bool> confirmBrowse(BuildContext c, BandEntry entry) async {
    if (!_isSecondarySensor(entry) || io.hasMainBand) return true;
    return showSensorWithoutBandSheet(c, sensor: entry);
  }

  /// Hands over to the main-band flow: the scan ends first, and where the
  /// system pairing sheet cannot open the user gets restart guidance instead.
  Future<AddDeviceResult> _handoff(BandEntry band) async {
    await io.stopScan();
    if (band.isFramed) {
      final held = await io.mainBandBlockedReason();
      if (held != null) return _r(AddDeviceOutcome.bandFlowHeldBack, held);
    }
    await io.openBandFlow(band);
    return _r(AddDeviceOutcome.openedBandFlow);
  }

  static bool _isSecondarySensor(BandEntry e) =>
      e.role == DeviceRole.sensor && e.category == DeviceCategory.workoutSensor;

  Future<AddDeviceResult> _pair(BuildContext c, BandCandidate cand,
      BandEntry entry,
      {PairConfirmation? confirmation}) async {
    final outcome = await io.pair(cand, entry, confirmation);
    // afterConnect checks `c.mounted` before it touches the context.
    // ignore: use_build_context_synchronously
    return afterConnect(c, cand, entry, outcome, confirmation: confirmation);
  }

  /// What happens after a connect that returned [outcome] for [cand] under
  /// [entry]: a band found asks again (nothing was saved) and re-runs only on
  /// an explicit yes. Shared by the nearby list and the category screen.
  Future<AddDeviceResult> afterConnect(
      BuildContext c, BandCandidate cand, BandEntry entry, PairOutcome outcome,
      {PairConfirmation? confirmation}) async {
    final found = outcome.isBand;
    if (found != null) {
      // The connect showed it is a band. Nothing was saved; ask again with
      // that in hand, and re-run only on an explicit yes.
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      final choice = await showBandFoundSheet(c,
          band: found, hasMainBand: io.hasMainBand, afterConnect: true);
      if (choice == null) return _r(AddDeviceOutcome.cancelled);
      if (choice == BandSheetChoice.asBand) return _handoff(found);
      if (!c.mounted) return _r(AddDeviceOutcome.cancelled);
      return _pair(c, cand, entry,
          confirmation: PairConfirmation(
              remoteId: cand.device.remoteId.str, bandEntryId: found.id));
    }
    final error = outcome.error;
    if (error != null) return _r(AddDeviceOutcome.failed, error);
    return _r(confirmation != null || _isSecondarySensor(entry)
        ? AddDeviceOutcome.pairedSecondary
        : AddDeviceOutcome.pairedOther);
  }
}
