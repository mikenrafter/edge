import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/med_buzzer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'alert_dispatcher_persistence_test.db';
  });
  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
  });
  tearDownAll(LocalDb.close);
  const rule = AlertRule(
    id: 'health',
    kind: 'health',
    destinations: 3,
    channelPolicyId: 'health',
  );

  test(
    'two independent production dispatchers atomically own each SQLite target',
    () async {
      var phones = 0, bands = 0;
      final gate = Completer<void>();
      AlertDispatcher create() => AlertDispatcher(
        phone: () async {
          phones++;
          await gate.future;
          return true;
        },
        band: () async {
          bands++;
          return true;
        },
        isConnected: () => true,
      );
      final now = DateTime.now();
      final a = create(), b = create();
      final pending = [
        a.dispatch(rule, eventId: 'same', sourceTime: now, historical: false),
        b.dispatch(rule, eventId: 'same', sourceTime: now, historical: false),
      ];
      while (phones == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      gate.complete();
      await Future.wait(pending);
      expect((phones, bands), (1, 1));
      await LocalDb.close();
      await create().dispatch(
        rule,
        eventId: 'same',
        sourceTime: now,
        historical: false,
      );
      expect(
        (phones, bands),
        (1, 1),
        reason: 'ownership survives database reopen',
      );
    },
  );

  test(
    'failed target releases only its own durable claim for next instance',
    () async {
      var phones = 0, bands = 0;
      AlertDispatcher create() => AlertDispatcher(
        phone: () async {
          phones++;
          return true;
        },
        band: () async => ++bands > 1,
        isConnected: () => true,
      );
      final now = DateTime.now();
      await create().dispatch(
        rule,
        eventId: 'retry',
        sourceTime: now,
        historical: false,
      );
      await LocalDb.close();
      await create().dispatch(
        rule,
        eventId: 'retry',
        sourceTime: now,
        historical: false,
      );
      expect((phones, bands), (1, 2));
    },
  );

  test(
    'NotificationCenter routes real persisted band-only choice without phone',
    () async {
      final prefs = await NotificationPrefs.load();
      await prefs.withAlertRule(rule.copyWith(destinations: 2).toJson()).save();
      final center = NotificationCenter.instance;
      final original = center.dispatcher, sink = center.presentSink;
      var phones = 0, bands = 0;
      center.presentSink = (e, {allowPermissionPrompt = true}) async {
        phones++;
        return true;
      };
      center.dispatcher = AlertDispatcher(
        phone: () async => false,
        band: () async {
          bands++;
          return true;
        },
        isConnected: () => true,
        ledger: const NotificationCenterDeliveryLedger(),
      );
      addTearDown(() {
        center.dispatcher = original;
        center.presentSink = sink;
      });
      final event = NotificationEvent(
        dedupeKey: 'center',
        category: NotifCategory.health,
        title: 'Alert',
        body: 'Alert',
        date: '2026-09-30',
      );
      await center.emit(event);
      await center.emit(event);
      expect((phones, bands), (0, 1));
    },
  );
  test(
    'two production medication timers share destination and durable occurrence ownership',
    () async {
      final prefs = await NotificationPrefs.load();
      await prefs
          .withAlertRule(
            prefs
                .alertRule('meds')
                .copyWith(enabled: true, destinations: 2)
                .toJson(),
          )
          .save();
      var calls = 0;
      AlertDispatcher create() => AlertDispatcher(
        phone: () async => false,
        band: () async {
          calls++;
          return true;
        },
        isConnected: () => true,
      );
      final a = MedBuzzer(
        buzz: () async {},
        isConnected: () => true,
        dispatcher: create(),
      );
      final b = MedBuzzer(
        buzz: () async {},
        isConnected: () => true,
        dispatcher: create(),
      );
      addTearDown(() {
        a.dispose();
        b.dispose();
      });
      final at = DateTime.now().add(const Duration(milliseconds: 60));
      a.configure(slotInstants: [at]);
      b.configure(slotInstants: [at]);
      // Poll for the first delivery so a loaded machine cannot fail the test
      // on timing, then wait out a second delivery before counting.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (calls == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(calls, 1);
    },
  );

  test(
    'timed-out transport retains durable ownership and reports unconfirmed',
    () async {
      final gate = Completer<bool>();
      var calls = 0;
      final d = AlertDispatcher(
        phone: () async => false,
        band: () {
          calls++;
          return gate.future;
        },
        isConnected: () => true,
        transportTimeout: const Duration(milliseconds: 10),
      );
      final now = DateTime.now();
      final selected = rule.copyWith(destinations: 2);
      final out = await d.dispatch(
        selected,
        eventId: 'timeout',
        sourceTime: now,
        historical: false,
      );
      expect(out.suppressionReason, 'deliveryUnconfirmed');
      await d.dispatch(
        selected,
        eventId: 'timeout',
        sourceTime: now,
        historical: false,
      );
      gate.complete(true);
      expect(
        calls,
        1,
        reason: 'the timed-out platform write can still complete',
      );
    },
  );
  test('historical derived event cannot acquire a fresh receipt-time band buzz', () async {
    final prefs = await NotificationPrefs.load();
    await prefs.withAlertRule(rule.copyWith(destinations: 2).toJson()).save();
    final center = NotificationCenter.instance;
    final original = center.dispatcher;
    var bands = 0;
    center.dispatcher = AlertDispatcher(phone: () async => false,
      band: () async { bands++; return true; }, isConnected: () => true);
    addTearDown(() => center.dispatcher = original);
    await center.emit(NotificationEvent(dedupeKey: 'old-derived',
      category: NotifCategory.health, title: 'Alert', body: 'Alert',
      date: dayLabelOf(DateTime.now().subtract(const Duration(days: 1)))));
    expect(bands, 0);
  });

  test('quiet hours suppress band delivery before consuming target ownership', () async {
    var prefs = await NotificationPrefs.load();
    prefs = prefs.copyWith(quietEnabled: true, quietStartMin: 0,
        quietEndMin: 1439, criticalOverridesQuiet: false);
    await prefs.withAlertRule(rule.copyWith(destinations: 2).toJson()).save();
    final center = NotificationCenter.instance;
    final original = center.dispatcher;
    var bands = 0;
    center.dispatcher = AlertDispatcher(phone: () async => false,
      band: () async { bands++; return true; }, isConnected: () => true);
    addTearDown(() => center.dispatcher = original);
    final event = NotificationEvent(dedupeKey: 'quiet-band',
      category: NotifCategory.health, title: 'Alert', body: 'Alert', date: todayLabel());
    await center.emit(event); expect(bands, 0);
    await (await NotificationPrefs.load()).copyWith(quietEnabled: false).save();
    await center.emit(event); expect(bands, 1);
  });

}
