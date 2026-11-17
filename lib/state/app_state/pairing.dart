part of '../app_state.dart';

// AppState retains band state; this part owns pairing persistence and the
// history-commit fence while a candidate has not become the primary.
extension _AppStatePairing on AppState {
  /// The system sheet chooses the replacement on iOS 18+. The tapped scan
  /// identity is not enforced by ASK. Picker errors retain the old pairing.
  Future<void> _replaceViaAccessorySetup() async {
    if (_pairingInProgress || _replacementPickerInProgress) {
      throw StateError('Pairing is already in progress.');
    }
    final old = paired;
    if (old == null) throw StateError('There is no band to replace.');
    final epoch = _pairingEpoch;
    _replacementPickerInProgress = true;
    try {
      await IosBleRestore.releaseCentralForPicker();
      final id = await AccessorySetup.showPicker(addAnother: true);
      if (epoch != _pairingEpoch || paired?.remoteId != old.remoteId) {
        throw StateError('The current pairing changed.');
      }
      await IosBleRestore.provisioned(id);
      await debugAfterReplacementProvisioned?.call();
      // The provisioning await can outlive a forget/reset that started after
      // the check above. _persistPaired captures the CURRENT epoch as its own,
      // so a stale picker result would otherwise enter replacement, and its
      // save could recreate the pairing the user just cancelled.
      if (epoch != _pairingEpoch || paired?.remoteId != old.remoteId) {
        throw StateError('The current pairing changed.');
      }
      _replacementPickerInProgress = false;
      await _persistPaired(id, null, replacing: true);
    } finally {
      _replacementPickerInProgress = false;
      // A dismissed/refused picker must not leave background restore disabled.
      final current = paired;
      if (current != null) await IosBleRestore.provisioned(current.remoteId);
    }
  }

  /// Forget what the link knows about the band it was on, so a new bootstrap
  /// starts clean. The remembered strap name is a separate, persisted thing:
  /// it is also what the old band is shown under while it is still the paired
  /// one, so a replacement that has not committed must leave it alone.
  void _resetBandIdentity({bool clearSavedName = true}) {
    _clearLiveHrTrace(LocalDb.kPrimaryDeviceId);
    device.reset();
    pairedIsMaverick = false;
    _lastSeenGeneration = null;
    _lastSeenStrapNameRaw = null;
    if (clearSavedName) Prefs.setString(AppState._kStrapName, '');
  }


  Future<void> _persistPaired(String remoteId, String? serial,
      {bool replacing = false}) async {
    if (_pairingInProgress || _replacementPickerInProgress) {
      throw StateError('Pairing is already in progress.');
    }
    if (Prefs.getBool(Prefs.demoModeEnabled, false)) {
      Prefs.setBool(Prefs.demoModeEnabled, false);
      await DemoDataGenerator.purge(app: this);
    }
    final existing = paired;
    final existingIsMaverick = pairedIsMaverick;
    if (existing != null && !replacing) {
      if (existing.remoteId != remoteId) {
        throw Exception('Forget the current band before pairing another.');
      }
      await openSession();
      if (!engine.isConnected) throw Exception('Connection setup did not complete.');
      return;
    }
    if (replacing && existing == null) throw StateError('There is no band to replace.');
    if (replacing && existing!.remoteId == remoteId) {
      throw const SameBandSelectedException();
    }
    final epoch = _pairingEpoch;
    // A reset empties the store without bumping the pairing epoch (only forget
    // does), and lowers the gate once it is done. Capture the generation too,
    // or a save that was queued behind a finished reset writes into the
    // emptied store and resurrects a pairing.
    final resetGen = ResetGate.generation;
    _pairingInProgress = true;
    _replacingBand = replacing;
    var committed = false;
    var started = false;
    try {
      // The primary peripheral must never also hold a secondary connection. A
      // candidate that is already a workout sensor here would be saved as the
      // primary with its secondary row and link still alive, and the sensor
      // link would reconnect the same peripheral. Refuse before anything starts.
      if (replacing &&
          (await LocalDb.deviceRows()).any((r) =>
              r['remote_id'] == remoteId &&
              r['id'] != LocalDb.kPrimaryDeviceId)) {
        throw Exception(
            'That device is already paired as a sensor. Forget it there first.');
      }
      final confirmed = await _sync.connectForPairing(
        PairedDevice(remoteId, serial),
        replacingRemoteId: replacing ? existing?.remoteId : null,
        onStarted: () => started = true,
        prepare: replacing ? () async {
          // Replacement suppresses disconnect callbacks; bank the old band's
          // still-filling minute before the new session clears its pedometer.
          await _finalizeLivePedometer();
          _resetBandIdentity(clearSavedName: false);
        } : null,
        confirm: () async {
          // Only READY proves we can talk to this band. Until then neither
          // the persisted record nor isPaired may advance onboarding. Save
          // the identity THIS bootstrap discovered, not a stale device hint.
          if (epoch != _pairingEpoch || ResetGate.changedSince(resetGen)) {
            throw StateError('Pairing was cancelled.');
          }
          if (replacing) {
            // CLAIM(alarm-band-ownership): bind legacy epochs before switching
            // identity, so a failed remove cannot arm the replacement on paper.
            final prefs = await SharedPreferences.getInstance();
            if (!await bindAlarmEpochToBand(prefs, existing!.remoteId)) {
              throw StateError('Could not preserve alarm ownership.');
            }
          }
          // The ownership write above can outlive a completed forget/reset;
          // PairedDevice must not start a new save after that cancellation.
          if (epoch != _pairingEpoch || ResetGate.changedSince(resetGen)) {
            throw StateError('Pairing was cancelled.');
          }
          await PairedDevice.save(remoteId, serial ?? device.serial,
              generation: device.generation);
          if (epoch != _pairingEpoch || ResetGate.changedSince(resetGen)) {
            throw StateError('Pairing was cancelled.');
          }
          // `save` returned, so the new band is durable. A failed read-back
          // must not be mistaken for a failed save: the catch below would
          // reconnect the OLD band while storage already names the new one,
          // and the next launch would disagree with this process. Publish
          // what was just written instead.
          final savedSerial = cleanDeviceLabel(serial ?? device.serial);
          final savedGeneration = device.generation;
          PairedDevice? reloaded;
          var reloadFailed = false;
          try {
            reloaded = await (debugLoadPaired?.call() ?? PairedDevice.load());
          } catch (e) {
            reloadFailed = true;
            _log('Paired band saved, but reading it back failed: $e');
          }
          paired = reloadFailed
              ? PairedDevice(remoteId, savedSerial,
                  generation: (savedGeneration == 'gen4' ||
                          savedGeneration == 'gen5')
                      ? savedGeneration
                      : null)
              : reloaded;
          committed = paired?.remoteId == remoteId;
          // The old band's name belongs to the old band; the new one banks
          // its own as soon as it reports it.
          if (committed && replacing) {
            Prefs.setString(AppState._kStrapName, '');
            // An epoch confirms the OLD physical band, never the replacement.
            // Clear persistence before openSession can reload it and skip SET.
            await _clearArmedAlarmState();
          }
        },
      );
      if (!confirmed) {
        final blocker = engine.bluetoothBlocker;
        if (blocker != null) throw BleUnavailableException(blocker);
        throw Exception('Connection setup did not complete.');
      }
      if (replacing && committed) {
        // CLAIM(pairing-retirement-lock): retirement can revoke approval; a
        // second replacement must wait until both native calls finish.
        await IosBleRestore.disarmOne(existing!.remoteId);
        await (debugRetireBandApproval?.call(existing.remoteId) ??
            AccessorySetup.removeBand(existing.remoteId));
      }
    } catch (error, stack) {
      // PairedDevice.save rolls back its transaction and preference mirror.
      // Only reconnect while the old pairing still owns this attempt.
      if (replacing && started && !committed && epoch == _pairingEpoch &&
          paired?.remoteId == existing?.remoteId) {
        _replacingBand = false;
        _resetBandIdentity(clearSavedName: false);
        pairedIsMaverick = existingIsMaverick;
        try {
          await IosBleRestore.provisioned(existing!.remoteId);
          await openSession();
        } catch (restoreError) {
          _log('Replacement failed; old band is still paired: $restoreError');
        }
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _replacingBand = false;
      _pairingInProgress = false;
    }
    if (replacing && committed) _onEngineState(LocalDb.kPrimaryDeviceId, device);
    // Now that there's a band to alert about, ask for notification permission
    // (a natural moment; battery/charging alerts depend on it). Best-effort.
    unawaited(NotificationService.instance.ensurePermission());
    // Android: associate the band with CompanionDeviceManager (one-time system
    // dialog) so the OS lets us restart the tracking service from the
    // background and — API 31+ — relaunches us when the band appears.
    // Fire-and-forget: logging happens inside; pairing must never block on it.
    unawaited(AndroidBackground.associateCompanion(remoteId));
    notifyListeners();
    await openSession();
  }


  Future<void> _unpairBand() async {
    await _endSnooze('unpaired');
    // The forgotten band's alarm gets no episode, whatever calls back later.
    final forgotten = alarmEpoch;
    if (forgotten != null) _quietDoneEpoch = forgotten;
    final forgottenBand = paired?.remoteId ?? (await PairedDevice.load())?.remoteId;
    if (forgottenBand != null) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt('alarm_epoch') != null &&
          !await bindAlarmEpochToBand(prefs, forgottenBand)) {
        _log('[alarm] could not clear or tag the forgotten band’s alarm');
      }
    }
    await _clearArmedAlarmState();
    await _sync.unpairSession();
    await PairedDevice.clear();
    pairedIsMaverick = false;
    // Everything the old band told us about itself. The engine's DeviceState
    // lives as long as the process and the persisted strap name outlives even
    // that, so without both of these a re-pair — with a DIFFERENT band —
    // inherits the forgotten one's name, serial, generation and bond verdicts.
    device.reset();
    Prefs.setString(AppState._kStrapName, '');
    // AND THE CHANGE GATES THAT GUARD WHAT THOSE TWO LINES JUST CLEARED. Both
    // are per-tick caches in [_onEngineState], and both compare against the
    // OLD band: pair a second band that reports the same generation and the
    // `device.adapter_id` write is skipped, leaving the new pairing's adapter
    // structurally blank (schema 49) and every per-family metric abstaining for
    // a reason that is our bookkeeping. Same for a same-named band and the
    // strap-name pref this method just emptied.
    _lastSeenGeneration = null;
    _lastSeenStrapNameRaw = null;
    paired = null;
    notifyListeners();
  }
}
