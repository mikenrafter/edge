// Android "Edge Tracking" foreground service.
//
// Keeps the app process alive while backgrounded so the live BLE connection keeps
// draining the strap (Android kills background processes otherwise). Shows a single
// silent, low-priority notification ("Edge Tracking"), the same trade modern Android
// requires for long-running BLE — there is no reliable background-BLE path without it.
//
// No-op on iOS: there, CoreBluetooth state restoration (BleRestoreManager) handles
// background relaunch silently, so no service/notification is needed.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class EdgeTracking {
  static const _ch = MethodChannel('openstrap/edge_tracking');

  // Whether the FGS should currently carry the `location` service type (a GPS
  // route session is live). Sticky across the frequent no-arg start() calls so
  // an unrelated keep-alive start can't silently strip the location type
  // mid-run; explicitly cleared with start(location: false) when the run ends.
  static bool _locationActive = false;

  // The service is shared. BLE tracking and workouts call [start] and want it
  // up until [stop]; a short job (a backup import) only needs it for its own
  // duration and goes through [hold]/[release]. Release stops the service only
  // when no holder remains AND nothing else asked for it, so an import that
  // finishes mid-sync can never stop the service the strap link needs.
  static bool _trackingWanted = false;
  static final Set<String> _holders = <String>{};

  /// Start the foreground service. Idempotent — safe to call on every session
  /// start. Pass [location] to add/remove the `location` foreground-service
  /// type (required for background GPS fixes during a route workout); omit it
  /// to keep the current mode.
  static Future<void> start({bool? location, String? holder}) async {
    if (!Platform.isAndroid) return;
    if (location != null) _locationActive = location;
    // A holder keeps the service up for its own duration only (see [hold]).
    if (holder != null) {
      _holders.add(holder);
    } else {
      _trackingWanted = true;
    }
    try {
      await _ch.invokeMethod('start', {'location': _locationActive});
    } catch (e) {
      debugPrint('[edge-tracking] start failed: $e');
    }
  }

  /// Stop the service (sign-out / unpair).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _trackingWanted = false;
    // A holder still needs the process alive; its release() stops it.
    if (_holders.isNotEmpty) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  /// Keep the service up for [holder] (e.g. 'import') without claiming the
  /// BLE-tracking lifetime. Idempotent per holder.
  static Future<void> hold(String holder) => start(holder: holder);

  /// Drop [holder]'s claim; stops the service only if nobody else wants it.
  /// Limit: the state is per Dart isolate, so a service started only by the
  /// headless engine is not seen here.
  static Future<void> release(String holder) async {
    if (!Platform.isAndroid) return;
    _holders.remove(holder);
    if (_holders.isNotEmpty || _trackingWanted) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}
