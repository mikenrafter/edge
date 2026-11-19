// UpdateCoordinator owns release discovery and the observable update state.
// No APK bytes, installer or companion endpoint participates; remote text
// never becomes a navigation destination.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/json_payload_lane.dart' show JsonPayloadDecodeLane;
import 'update_models.dart';
import 'update_store.dart';
export 'update_models.dart';

const updateTaskName = 'edge.github.release-check.v1';

class UpdateCoordinator extends ChangeNotifier {
  UpdateCoordinator({
    required this.store,
    required this.client,
    required this.installed,
    required this.now,
    required this.unmetered,
    required this.schedule,
    this.onRelease,
    this.clientFactory,
    this.jitter,
    this.lane,
  });
  final UpdateStore store;
  final http.Client client;
  final http.Client Function()? clientFactory;
  final InstalledRelease installed;
  final DateTime Function() now;
  final Future<bool> Function() unmetered;
  final Future<void> Function(bool) schedule;
  final Future<void> Function(ReleaseCandidate)? onRelease;
  final Duration Function()? jitter;

  /// Where metadata JSON is parsed (a registered worker); defaults to the shared
  /// isolate lane.
  final JsonPayloadDecodeLane? lane;
  UpdateSnapshot snapshot = const UpdateSnapshot();

  Future<void> load() async {}
  Future<void> setEnabled(bool enabled) async {}
  Future<void> setOfficialPrereleases(bool enabled) async {}
  Future<CheckOutcome> check({bool manual = false}) async =>
      const CheckFailed(UpdateError.storage);

  /// Re-offer fresh cached announcements held by quiet hours or sleep.
  Future<void> releaseHeld() async {}
}
