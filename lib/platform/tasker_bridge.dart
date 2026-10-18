import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/prefs.dart';
import 'tasker_play.dart';

class TaskerBridge {
  static const _ch = MethodChannel('openstrap/tasker');

  final Future<void> Function(int pattern) buzzPattern;

  /// Plays what a `tasker_play` call asked for (a slot or a pattern) as an
  /// ordinary job of the band queue. Null: such a call is ignored.
  final Future<void> Function(TaskerPlayRequest request)? playRequest;

  /// "Tasker connection", read on every incoming call. Null: the stored
  /// switch (on unless turned off).
  final bool Function() connectionOn;

  final void Function(String line)? log;

  TaskerBridge({
    required this.buzzPattern,
    this.playRequest,
    bool Function()? connectionOn,
    this.log,
  }) : connectionOn = connectionOn ?? (() => Prefs.taskerConnectionOn) {
    _ch.setMethodCallHandler(_onMethodCall);
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method != 'buzz_strap' && call.method != 'tasker_play') return;
    // Everything Tasker sends is part of the integration the wearer can turn
    // off; off means nothing reaches the band.
    if (!connectionOn()) {
      _note('[tasker] ignored ${call.method}: the Tasker connection is off');
      return;
    }
    if (call.method == 'tasker_play') {
      final request = parseTaskerPlay(call.arguments);
      final play = playRequest;
      if (request == null || play == null) {
        _note('[tasker] ignored tasker_play: nothing known to play in '
            '${call.arguments}');
        return;
      }
      // Not awaited: a play can wait minutes for the band's command window,
      // and the native sender does not need an answer.
      unawaited(play(request).catchError((Object e, StackTrace st) {
        debugPrint('[tasker] play failed: $e\n$st');
      }));
      return;
    }
    if (call.method == 'buzz_strap') {
      try {
        final args = call.arguments;
        debugPrint('[tasker] _onMethodCall args=$args (${args.runtimeType})');
        final map = args is Map ? args : <dynamic, dynamic>{};
        final pattern = (map['pattern'] as int?) ?? 2;
        debugPrint('[tasker] buzz pattern=$pattern');
        await buzzPattern(pattern);
      } catch (e, st) {
        debugPrint('[tasker] buzz failed: $e\n$st');
      }
    }
  }

  void _note(String line) {
    debugPrint(line);
    log?.call(line);
  }

  /// Read (without clearing) a buzz Tasker requested while the app was fully
  /// dead — see TaskerReceiver.kt's "engine dead" fallback. This goes through
  /// a native method-channel call reading the SAME native SharedPreferences
  /// file ("openstrap_runtime") TaskerReceiver writes to directly. The
  /// `shared_preferences` PLUGIN reads/writes a DIFFERENT, plugin-managed
  /// store (its own file, `flutter.`-prefixed keys) — it can never see what
  /// TaskerReceiver persisted, so do not "simplify" this back to
  /// `SharedPreferences.getInstance()`.
  static Future<int?> peekPendingBuzz() async {
    try {
      return await _ch.invokeMethod<int>('peek_pending_buzz');
    } catch (_) {
      return null;
    }
  }

  /// Clear the pending flag. Call ONLY after the buzz was actually delivered
  /// (see AppState._checkPendingTaskerBuzz) — never as part of the read —
  /// so a request that couldn't be sent yet (no BLE connection) survives to
  /// the next attempt instead of being silently dropped.
  static Future<void> clearPendingBuzz() async {
    try {
      await _ch.invokeMethod('clear_pending_buzz');
    } catch (_) {}
  }

  /// Rate-limit for outbound events, at the emit site. A reconnect storm can
  /// complete several offloads in a minute and each one would otherwise fire a
  /// broadcast that wakes every automation profile listening for it.
  static const Duration _minEventGap = Duration(seconds: 60);
  static DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tasker's Android package: the only recipient of health-carrying events.
  static const String taskerPackage = 'net.dinglisch.android.taskerm';

  /// Tests only: pretend to be (or not to be) Android.
  @visibleForTesting
  static bool? debugAndroidOverride;

  /// Tests only: forget the last emit time.
  @visibleForTesting
  static void debugResetRateLimit() =>
      _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Fire an OUTBOUND automation event: an Android broadcast the user's Tasker
  /// (or Automate, or MacroDroid) profile can trigger on.
  ///
  /// **ANDROID ONLY, and the docs must say so rather than implying parity.**
  /// iOS has no public mechanism for a Shortcuts personal automation to trigger
  /// on an arbitrary app-donated intent — the trigger list is a fixed system
  /// set. `donate`/`INInteraction` buys Siri suggestions and discoverability,
  /// not an event trigger. So iOS gets more intents the user invokes; it does
  /// not get events that invoke the user's shortcut, and pretending otherwise
  /// would be a promise the platform cannot keep.
  ///
  /// [extras] may carry FACTS (counts, timestamps, flags) and must never carry
  /// a derived metric. A number that the UI would have rendered as absent —
  /// with a tier and a note explaining why — becomes a bare `0` once it leaves
  /// the app, where nobody can see that it was never measured. Pass absence as
  /// absence: omit the key.
  static Future<bool> emitEvent(
    String event, {
    Map<String, Object> extras = const {},
    // false skips the 60 s gap and leaves `_lastEmit` alone, for callers that
    // send one broadcast per item (the moment review).
    bool rateLimited = true,
    // Restricts the broadcast to ONE receiving app (NativeChannels.kt calls
    // Intent.setPackage). Null keeps the open broadcast every automation app
    // (Tasker, Automate, MacroDroid) can listen to.
    String? package,
  }) async {
    if (!(debugAndroidOverride ?? Platform.isAndroid)) return false;
    if (rateLimited) {
      final now = DateTime.now();
      if (now.difference(_lastEmit) < _minEventGap) return false;
      _lastEmit = now;
    }
    try {
      return await _ch.invokeMethod<bool>('emit_event', {
            'event': event,
            'extras': extras,
            'package': ?package,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The one event that ships. `records` is how many the offload actually
  /// stored — a fact about the sync, not a measurement of the user.
  static Future<bool> emitSyncComplete({required int records}) => emitEvent(
        'SYNC_COMPLETE',
        extras: {
          'records': records,
          'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
      );

  /// The per-install secret Tasker (or any automation app) must echo back as
  /// the `token` string extra on its BUZZ_STRAP broadcast — generated once
  /// and persisted natively on first request. Surfaced in Settings →
  /// Automation for the user to copy into their Tasker action; without it,
  /// the exported, permission-less receiver would let any installed app
  /// trigger strap haptics. Returns null only on a channel/platform failure.
  static Future<String?> authToken() async {
    try {
      return await _ch.invokeMethod<String>('get_auth_token');
    } catch (_) {
      return null;
    }
  }
}
