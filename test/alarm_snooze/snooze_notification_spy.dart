// The phone notifications the app scheduled and cancelled, read off the
// platform channel (flutter_local_notifications has no other seam). Android is
// the platform, so the plugin takes the zonedSchedule path.
//
// Also answers `canScheduleExactNotifications` (the OS "may this app set exact
// alarms" question): [canExact] null is "not answered" (the plugin reads null),
// which a caller must treat as no.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const MethodChannel _channel =
    MethodChannel('dexterous.com/flutter/local_notifications');

typedef Scheduled = ({int id, DateTime at, String? mode});

class NotificationSpy {
  final scheduled = <Scheduled>[];
  final cancelled = <int>[];
  final order = <String>[];

  /// What the OS says to "can this app schedule exact alarms".
  bool? canExact;

  /// How many times the app asked.
  int exactAsked = 0;

  void install() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));
    NotificationService.instance.debugProbePermission = () async => true;
    NotificationService.instance.debugRequestPermission = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final a = call.arguments;
      if (call.method == 'zonedSchedule' && a is Map) {
        final at = DateTime.parse(a['scheduledDateTimeISO8601'] as String);
        final specifics = a['platformSpecifics'];
        scheduled.add((
          id: a['id'] as int,
          at: at,
          mode: specifics is Map ? specifics['scheduleMode'] as String? : null,
        ));
        order.add('schedule:${a['id']}');
      } else if (call.method == 'cancel' && a is Map) {
        cancelled.add(a['id'] as int);
        order.add('cancel:${a['id']}');
      } else if (call.method == 'cancel' && a is int) {
        cancelled.add(a);
        order.add('cancel:$a');
      } else if (call.method == 'cancelAll') {
        order.add('cancelAll');
      } else if (call.method == 'canScheduleExactNotifications') {
        exactAsked++;
        return canExact;
      }
      return null;
    });
  }

  void uninstall() {
    debugDefaultTargetPlatformOverride = null;
    NotificationService.instance.debugProbePermission = null;
    NotificationService.instance.debugRequestPermission = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  /// The newest schedule within 2 s of [due], or null.
  Scheduled? at(DateTime due) {
    for (final s in scheduled.reversed) {
      if (s.at.difference(due).abs() <= const Duration(seconds: 2)) return s;
    }
    return null;
  }

  /// The id scheduled for within 2 s of [due], or null.
  int? idFor(DateTime due) => at(due)?.id;

  /// True when the last thing done to [id] was a cancel (nothing re-armed it).
  bool endsCancelled(int id) {
    final c = order.lastIndexOf('cancel:$id');
    return c >= 0 && c > order.lastIndexOf('schedule:$id');
  }

  /// True when the last thing done to [id] was a schedule.
  bool endsScheduled(int id) {
    final s = order.lastIndexOf('schedule:$id');
    return s >= 0 && s > order.lastIndexOf('cancel:$id');
  }
}
