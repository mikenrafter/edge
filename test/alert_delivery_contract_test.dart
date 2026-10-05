import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'support/controls_contract.dart';

Map<String, Object?> rule(
  int targets, {
  String replay = 'liveOnly',
  String fallback = 'none',
}) => {
  'id': 'health',
  'kind': 'health',
  'enabled': targets != 0,
  'destinations': targets,
  'executionMode': 'phoneDerived',
  'fallback': fallback,
  'staleAfterSeconds': 30,
  'historicalReplay': replay,
  'channelPolicyId': 'health',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<Map<String, dynamic>> storedRule(String id) async {
    final dynamic prefs = await NotificationPrefs.load();
    return contract(
      'typed migrated rule $id',
      () => Map<String, dynamic>.from(prefs.alertRule(id).toJson() as Map),
    );
  }

  dynamic dispatcher({
    required Future<bool> Function() phone,
    required Future<bool> Function() band,
    bool connected = true,
    Set<String> supported = const {'phone', 'band'},
    DateTime? now,
  }) {
    final dynamic app = AppState.forTesting();
    return contract(
      'single production alert dispatcher',
      () => app.debugAlertDispatcher(
        phone: phone,
        band: band,
        isConnected: () => connected,
        supportedTargets: supported,
        now: () => now ?? DateTime(2026, 9, 30, 12),
      ),
    );
  }

  for (final mask in [0, 1, 2, 3]) {
    test(
      'destination mask $mask round-trips without enabling any extra target',
      () async {
        final dynamic prefs = await NotificationPrefs.load();
        final dynamic next = contract(
          'destination set update',
          () => prefs.withAlertRule(rule(mask)),
        );
        await next.save();
        final loaded = await storedRule('health');
        expect(loaded['destinations'], mask);
        expect(loaded['fallback'], 'none');
      },
    );
    test('destination mask $mask delivers only selected transports', () async {
      var phones = 0, bands = 0;
      final d = dispatcher(
        phone: () async {
          phones++;
          return true;
        },
        band: () async {
          bands++;
          return true;
        },
      );
      final outcome = await d.dispatch(
        rule(mask),
        eventId: 'one',
        sourceTime: DateTime(2026, 9, 30, 12),
        historical: false,
      );
      expect(phones, (mask & 1) == 0 ? 0 : 1);
      expect(bands, (mask & 2) == 0 ? 0 : 1);
      expect(outcome.targets.toSet(), {
        if ((mask & 1) != 0) 'phone',
        if ((mask & 2) != 0) 'band',
      });
    });
  }
  for (final enabled in [false, true]) {
    test(
      'legacy enabled=$enabled migrates phone and band destinations independently and once',
      () async {
        SharedPreferences.setMockInitialValues({
          'notif_health': enabled,
          'notif_water': enabled,
        });
        final health = await storedRule('health'),
            water = await storedRule('water');
        expect(health['destinations'], enabled ? 1 : 0);
        expect(
          water['destinations'],
          enabled ? 3 : 0,
          reason: 'water already scheduled phone plus band',
        );
        expect(health['fallback'], 'none');
        expect(water['historicalReplay'], 'liveOnly');
        final dynamic p = await NotificationPrefs.load();
        await contract(
          'migration can be saved',
          () => p.withAlertRule(rule(2)),
        ).save();
        final store = await SharedPreferences.getInstance();
        await store.setBool('notif_health', !enabled);
        expect(
          (await storedRule('health'))['destinations'],
          2,
          reason: 'legacy flags cannot rerun migration',
        );
      },
    );
  }
  test('unavailable band never silently gains phone fallback', () async {
    var phones = 0, bands = 0;
    final d = dispatcher(
      connected: false,
      phone: () async {
        phones++;
        return true;
      },
      band: () async {
        bands++;
        return true;
      },
    );
    final out = await d.dispatch(
      rule(2),
      eventId: 'x',
      sourceTime: DateTime(2026, 9, 30, 12),
      historical: false,
    );
    expect((phones, bands), (0, 0));
    expect(out.suppressionReason, 'bandUnavailable');
  });
  test('explicit unavailable-band phone fallback is honored', () async {
    var phones = 0, bands = 0;
    final d = dispatcher(
      connected: false,
      phone: () async {
        phones++;
        return true;
      },
      band: () async {
        bands++;
        return true;
      },
    );
    await d.dispatch(
      rule(2, fallback: 'phoneIfBandUnavailable'),
      eventId: 'x',
      sourceTime: DateTime(2026, 9, 30, 12),
      historical: false,
    );
    expect((phones, bands), (1, 0));
  });
  test(
    'unsupported target is suppressed, selected phone can still deliver',
    () async {
      var phones = 0, bands = 0;
      final d = dispatcher(
        supported: {'phone'},
        phone: () async {
          phones++;
          return true;
        },
        band: () async {
          bands++;
          return true;
        },
      );
      final out = await d.dispatch(
        rule(3),
        eventId: 'x',
        sourceTime: DateTime(2026, 9, 30, 12),
        historical: false,
      );
      expect((phones, bands), (1, 0));
      expect(out.targets.toSet(), {'phone'});
    },
  );
  for (final replay in ['liveOnly', 'ask', 'historical']) {
    test(
      '$replay replay policy gates history independently of target',
      () async {
        var phones = 0, bands = 0;
        final d = dispatcher(
          phone: () async {
            phones++;
            return true;
          },
          band: () async {
            bands++;
            return true;
          },
        );
        await d.dispatch(
          rule(3, replay: replay),
          eventId: 'x',
          sourceTime: DateTime(2026, 9, 30, 11, 59, 50),
          historical: true,
        );
        expect((phones, bands), replay == 'historical' ? (1, 1) : (0, 0));
      },
    );
  }
  test('expired live event never buzzes on reconnect or emits phone', () async {
    var calls = 0;
    final d = dispatcher(
      phone: () async {
        calls++;
        return true;
      },
      band: () async {
        calls++;
        return true;
      },
    );
    final out = await d.dispatch(
      rule(3),
      eventId: 'old',
      sourceTime: DateTime(2026, 9, 30, 11, 59),
      historical: false,
    );
    expect(calls, 0);
    expect(out.suppressionReason, 'stale');
  });
  test('atomic concurrent dispatch emits each selected target once', () async {
    var phones = 0, bands = 0;
    final gate = Completer<void>();
    final d = dispatcher(
      phone: () async {
        phones++;
        await gate.future;
        return true;
      },
      band: () async {
        bands++;
        return true;
      },
    );
    final pending = [
      for (var i = 0; i < 8; i++)
        d.dispatch(
          rule(3),
          eventId: 'same',
          sourceTime: DateTime(2026, 9, 30, 12),
          historical: false,
        ),
    ];
    await flushOperations();
    gate.complete();
    await Future.wait<dynamic>(pending.cast<Future<dynamic>>());
    expect((phones, bands), (1, 1));
  });
  test(
    'failed target does not prevent other target and can retry without duplicating success',
    () async {
      var phones = 0, bands = 0;
      final d = dispatcher(
        phone: () async {
          phones++;
          return true;
        },
        band: () async {
          return ++bands > 1;
        },
      );
      for (var i = 0; i < 2; i++) {
        await d.dispatch(
          rule(3),
          eventId: 'retry',
          sourceTime: DateTime(2026, 9, 30, 12),
          historical: false,
        );
      }
      expect((phones, bands), (1, 2));
    },
  );
}
