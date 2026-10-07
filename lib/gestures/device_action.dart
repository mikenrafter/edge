// device_action.dart — the platform-agnostic catalogue of things a band gesture
// (today: double-tap) can trigger. The enum is the single source of truth shared by
// the settings UI, the persisted mapping, and the native dispatch channel.
//
// Adding a new NATIVE action is one entry here + one `case` in the native handlers:
// NativeChannels.kt on Android, the ActionBridge enum in AppDelegate.swift on iOS.
// An IN-APP action needs neither — one `case` in GestureDispatcher and a handler
// wired from AppState, and it works on every platform.
//
// Whether a platform actually SUPPORTS a native action is reported at runtime by
// DeviceActions.capabilities() — the UI only offers what the current OS can do, so
// e.g. volume control simply doesn't appear on iOS.
//
// FUTURE (deliberately not wired yet — each needs more than a no-risk API or a
// product decision): answer/reject call (Android ANSWER_PHONE_CALLS; impossible on
// iOS), workout lap.

import 'package:flutter/widgets.dart' show BuildContext;

import '../l10n/app_localizations.dart';

enum DeviceAction {
  none,
  mediaPlayPause,
  mediaNext,
  mediaPrev,
  volumeUp,
  volumeDown,
  ringPhone,
  torch,
  // In-app actions — act on our own app/backend, so they work on every platform
  // (iOS can't reach other apps, but it can always do these).
  markMoment,
  workoutToggle,
  logWater,
  // Native broadcast — sends an Android broadcast intent for Tasker to subscribe
  // to (see NativeChannels.kt). Only offered on Android.
  broadcastToTasker,
  // In-app: buzzes the current local time on the band (see time_buzz.dart).
  // APPENDED LAST: the enum order is the persisted bitmask, never reorder.
  tellTime,
}

extension DeviceActionX on DeviceAction {
  /// Stable wire id — used as the SharedPreferences value AND the `action` arg sent
  /// over the method channel. Never change these once shipped (persisted).
  String get id {
    switch (this) {
      case DeviceAction.none:
        return 'none';
      case DeviceAction.mediaPlayPause:
        return 'media_play_pause';
      case DeviceAction.mediaNext:
        return 'media_next';
      case DeviceAction.mediaPrev:
        return 'media_prev';
      case DeviceAction.volumeUp:
        return 'volume_up';
      case DeviceAction.volumeDown:
        return 'volume_down';
      case DeviceAction.ringPhone:
        return 'ring_phone';
      case DeviceAction.torch:
        return 'torch';
      case DeviceAction.markMoment:
        return 'mark_moment';
      case DeviceAction.workoutToggle:
        return 'workout_toggle';
      case DeviceAction.logWater:
        return 'log_water';
      case DeviceAction.broadcastToTasker:
        return 'broadcast_to_tasker';
      case DeviceAction.tellTime:
        return 'tell_time';
    }
  }

  /// Short label for the settings picker.
  String get label {
    switch (this) {
      case DeviceAction.none:
        return 'Do nothing';
      case DeviceAction.mediaPlayPause:
        return 'Play / pause music';
      case DeviceAction.mediaNext:
        return 'Next track';
      case DeviceAction.mediaPrev:
        return 'Previous track';
      case DeviceAction.volumeUp:
        return 'Volume up';
      case DeviceAction.volumeDown:
        return 'Volume down';
      case DeviceAction.ringPhone:
        return 'Ring my phone';
      case DeviceAction.torch:
        return 'Flashlight';
      case DeviceAction.markMoment:
        return 'Mark a moment';
      case DeviceAction.workoutToggle:
        return 'Start / stop workout';
      case DeviceAction.logWater:
        return 'Log water';
      case DeviceAction.broadcastToTasker:
        return 'Broadcast to Tasker';
      case DeviceAction.tellTime:
        return 'Tell the time';
    }
  }

  /// One-line description shown under the label.
  String get blurb {
    switch (this) {
      case DeviceAction.none:
        return 'Double-tap does nothing.';
      case DeviceAction.mediaPlayPause:
        return 'Toggle whatever is playing.';
      case DeviceAction.mediaNext:
        return 'Skip to the next track.';
      case DeviceAction.mediaPrev:
        return 'Go back a track.';
      case DeviceAction.volumeUp:
        return 'Raise media volume a step.';
      case DeviceAction.volumeDown:
        return 'Lower media volume a step.';
      case DeviceAction.ringPhone:
        return 'Play a loud sound so you can find your phone.';
      case DeviceAction.torch:
        return "Toggle your phone's flashlight.";
      case DeviceAction.markMoment:
        return 'Tag the current moment in your journal.';
      case DeviceAction.workoutToggle:
        return 'Begin or end a workout from your wrist.';
      case DeviceAction.logWater:
        return 'Add one glass to today\'s water total, like the + button on the '
               'nutrition screen.';
      case DeviceAction.broadcastToTasker:
        return 'Send an Android broadcast message that a Tasker task can listen for.';
      case DeviceAction.tellTime:
        return 'Buzz the current time on the band.';
    }
  }

  /// Localized [label], falling back to the English string above when there is
  /// no [AppLocalizations] in scope (e.g. a widget test with no delegate
  /// wired). `.label`/`.blurb` stay pure and untouched — same split as
  /// `sourceTierLabel`/`sourceTierDetail` in devices.dart.
  String localizedLabel(BuildContext c) {
    final l = AppLocalizations.of(c);
    switch (this) {
      case DeviceAction.none:
        return l?.deviceActionNoneLabel ?? label;
      case DeviceAction.mediaPlayPause:
        return l?.deviceActionMediaPlayPauseLabel ?? label;
      case DeviceAction.mediaNext:
        return l?.deviceActionMediaNextLabel ?? label;
      case DeviceAction.mediaPrev:
        return l?.deviceActionMediaPrevLabel ?? label;
      case DeviceAction.volumeUp:
        return l?.deviceActionVolumeUpLabel ?? label;
      case DeviceAction.volumeDown:
        return l?.deviceActionVolumeDownLabel ?? label;
      case DeviceAction.ringPhone:
        return l?.deviceActionRingPhoneLabel ?? label;
      case DeviceAction.torch:
        return l?.deviceActionTorchLabel ?? label;
      case DeviceAction.markMoment:
        return l?.deviceActionMarkMomentLabel ?? label;
      case DeviceAction.workoutToggle:
        return l?.deviceActionWorkoutToggleLabel ?? label;
      case DeviceAction.logWater:
        return l?.deviceActionLogWaterLabel ?? label;
      case DeviceAction.broadcastToTasker:
        return l?.deviceActionBroadcastToTaskerLabel ?? label;
      case DeviceAction.tellTime:
        return l?.deviceActionTellTimeLabel ?? label;
    }
  }

  /// Localized [blurb] — see [localizedLabel].
  String localizedBlurb(BuildContext c) {
    final l = AppLocalizations.of(c);
    switch (this) {
      case DeviceAction.none:
        return l?.deviceActionNoneBlurb ?? blurb;
      case DeviceAction.mediaPlayPause:
        return l?.deviceActionMediaPlayPauseBlurb ?? blurb;
      case DeviceAction.mediaNext:
        return l?.deviceActionMediaNextBlurb ?? blurb;
      case DeviceAction.mediaPrev:
        return l?.deviceActionMediaPrevBlurb ?? blurb;
      case DeviceAction.volumeUp:
        return l?.deviceActionVolumeUpBlurb ?? blurb;
      case DeviceAction.volumeDown:
        return l?.deviceActionVolumeDownBlurb ?? blurb;
      case DeviceAction.ringPhone:
        return l?.deviceActionRingPhoneBlurb ?? blurb;
      case DeviceAction.torch:
        return l?.deviceActionTorchBlurb ?? blurb;
      case DeviceAction.markMoment:
        return l?.deviceActionMarkMomentBlurb ?? blurb;
      case DeviceAction.workoutToggle:
        return l?.deviceActionWorkoutToggleBlurb ?? blurb;
      case DeviceAction.logWater:
        return l?.deviceActionLogWaterBlurb ?? blurb;
      case DeviceAction.broadcastToTasker:
        return l?.deviceActionBroadcastToTaskerBlurb ?? blurb;
      case DeviceAction.tellTime:
        return l?.deviceActionTellTimeBlurb ?? blurb;
    }
  }

  /// In-app actions act on our own app/backend (handled in Dart, no native call,
  /// available on every platform). Everything else (except `none`) is native.
  bool get isInApp =>
      this == DeviceAction.markMoment ||
      this == DeviceAction.workoutToggle ||
      this == DeviceAction.logWater ||
      this == DeviceAction.tellTime;

  bool get isNative => this != DeviceAction.none && !isInApp;

  /// Safe to run for a tap that is replayed from history (the band's flash)
  /// rather than felt now. True only for actions that record a moment in time;
  /// anything that acts on the phone right now (media, torch, water, workout)
  /// would fire hours late.
  bool get supportsHistoricalReplay => this == DeviceAction.markMoment;

  /// A long-running mode that takes over the band while it runs, so it cannot
  /// share a gesture slot with any other action. ECG is the one today, but it
  /// is the separate `GestureSettings.ecgOnDoubleTap` flag, not a
  /// [DeviceAction]; this is where a future action says it is one.
  bool get isActiveMode => false;

  static DeviceAction? fromId(String? id) {
    if (id == null) return null;
    for (final a in DeviceAction.values) {
      if (a.id == id) return a;
    }
    return null;
  }
}
