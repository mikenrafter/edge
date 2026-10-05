import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'support/controls_contract.dart';

Map<String, Object?> metadata({
  String category = 'msg',
  String key = 'key',
  String kind = 'post',
  int posted = 1000000,
  bool interruptionMatch = true,
}) => {
  'category': category,
  'package': 'com.example',
  'keyHash': key,
  'kind': kind,
  'postTimeMs': posted,
  'receiptTimeMs': 1000000,
  'matchesInterruptionFilter': interruptionMatch,
  'interruptionFilter': 1,
  'ringerMode': 2,
  'ongoing': false,
  'groupSummary': false,
  'importance': 3,
};
Map<String, Object?> policy({
  bool dnd = false,
  bool override = false,
  String ringer = 'normal',
  bool vibrate = true,
  bool silent = false,
  bool connected = true,
  String fallback = 'none',
  String worn = 'worn',
  bool onlyWorn = false,
}) => {
  'enabled': true,
  'dnd': dnd,
  'respectDnd': true,
  'allowDuringDnd': override,
  'ringer': ringer,
  'includeVibrate': vibrate,
  'includeSilent': silent,
  'connected': connected,
  'fallback': fallback,
  'worn': worn,
  'onlyWhileWorn': onlyWorn,
  'packages': ['com.example'],
  'staleAfterMs': 30000,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  dynamic controller({
    Map<String, Object?>? selectedPolicy,
    Future<bool> Function(List<int>)? buzz,
    Future<bool> Function()? phone,
  }) {
    final dynamic relay = NotificationRelay(
      buzz: () async {},
      isConnected: () => true,
    );
    return contract(
      'app-owned metadata relay controller',
      () => relay.debugController(
        policy: selectedPolicy ?? policy(),
        buzz: buzz ?? (_) async => true,
        phone: phone ?? () async => true,
        nowMs: () => 1000000,
      ),
    );
  }

  for (final channel in ['apps', 'alarms', 'calls']) {
    String category = channel == 'alarms'
        ? 'alarm'
        : channel == 'calls'
        ? 'call'
        : 'msg';
    test('$channel DND/ringer/connectivity/wear decision matrix', () async {
      for (final dnd in [false, true]) {
        for (final override in [false, true]) {
          for (final ringer in ['normal', 'vibrate', 'silent']) {
            for (final include in [false, true]) {
              for (final connected in [false, true]) {
                for (final worn in ['worn', 'notWorn', 'unknown']) {
                  var buzzes = 0, phones = 0;
                  final c = controller(
                    selectedPolicy: policy(
                      dnd: dnd,
                      override: override,
                      ringer: ringer,
                      vibrate: include,
                      silent: include,
                      connected: connected,
                      worn: worn,
                      onlyWorn: true,
                    ),
                    buzz: (_) async {
                      buzzes++;
                      return true;
                    },
                    phone: () async {
                      phones++;
                      return true;
                    },
                  );
                  c.setChannel(channel, enabled: true);
                  await c.handleMetadata(metadata(category: category));
                  final allowed =
                      (!dnd || override) &&
                      (ringer == 'normal' || include) &&
                      connected &&
                      worn == 'worn';
                  expect(
                    buzzes,
                    allowed ? 1 : 0,
                    reason:
                        '$channel dnd=$dnd override=$override ringer=$ringer include=$include connected=$connected worn=$worn',
                  );
                  expect(phones, 0, reason: 'no implicit phone fallback');
                  c.dispose();
                }
              }
            }
          }
        }
      }
    });
    test('$channel fallback is explicit and never bypasses DND', () async {
      for (final fallback in ['none', 'phoneIfBandUnavailable']) {
        for (final dnd in [false, true]) {
          var phones = 0;
          final c = controller(
            selectedPolicy: policy(
              connected: false,
              fallback: fallback,
              dnd: dnd,
            ),
            phone: () async {
              phones++;
              return true;
            },
          );
          c.setChannel(channel, enabled: true);
          await c.handleMetadata(metadata(category: category));
          expect(phones, !dnd && fallback != 'none' ? 1 : 0);
          c.dispose();
        }
      }
    });
  }
  test(
    'alarms and calls remain opt-in and independent of app allow-list',
    () async {
      var buzzes = 0;
      final c = controller(
        selectedPolicy: {...policy(), 'packages': <String>[]},
        buzz: (_) async {
          buzzes++;
          return true;
        },
      );
      for (final category in ['alarm', 'call']) {
        await c.handleMetadata(
          metadata(category: category, key: 'off-$category'),
        );
      }
      expect(buzzes, 0);
      c.setChannel('alarms', enabled: true);
      c.setChannel('calls', enabled: true);
      for (final category in ['alarm', 'call']) {
        await c.handleMetadata(
          metadata(category: category, key: 'on-$category'),
        );
      }
      expect(buzzes, 2);
    },
  );
  test(
    'call category classifies system and VoIP calls without text heuristics',
    () async {
      var buzzes = 0;
      final c = controller(
        selectedPolicy: {...policy(), 'packages': <String>[]},
        buzz: (_) async {
          buzzes++;
          return true;
        },
      );
      c.setChannel('calls', enabled: true);
      for (final pkg in ['com.android.dialer', 'com.example.voip']) {
        await c.handleMetadata({
          ...metadata(category: 'call', key: pkg),
          'package': pkg,
        });
      }
      expect(buzzes, 2);
    },
  );
  test(
    'updates share stable-key lifetime; removal permits the next occurrence',
    () async {
      var buzzes = 0;
      final c = controller(
        buzz: (_) async {
          buzzes++;
          return true;
        },
      );
      c.setChannel('apps', enabled: true);
      await c.handleMetadata(metadata());
      await c.handleMetadata(metadata(kind: 'update'));
      await c.handleMetadata(metadata(key: 'different'));
      expect(
        buzzes,
        2,
        reason: 'distinct notification keys from the same package are distinct',
      );
      await c.handleMetadata(metadata(kind: 'remove'));
      expect(buzzes, 2);
      await c.handleMetadata(metadata());
      expect(buzzes, 3);
    },
  );
  test('concurrent same-key posts produce one buzz', () async {
    var buzzes = 0;
    final c = controller(
      buzz: (_) async {
        buzzes++;
        await flushOperations();
        return true;
      },
    );
    c.setChannel('apps', enabled: true);
    await Future.wait<dynamic>([
      for (var i = 0; i < 8; i++) c.handleMetadata(metadata()),
    ]);
    expect(buzzes, 1);
  });
  test('interruption ranking blocks unmatched posts during DND', () async {
    var buzzes = 0;
    final c = controller(
      selectedPolicy: policy(dnd: true),
      buzz: (_) async {
        buzzes++;
        return true;
      },
    );
    c.setChannel('apps', enabled: true);
    await c.handleMetadata(metadata(interruptionMatch: false));
    expect(buzzes, 0);
  });
  test(
    'alarm pattern matching uses readable metadata or disclosed fallback',
    () async {
      final patterns = <List<int>>[];
      final c = controller(
        buzz: (p) async {
          patterns.add(p);
          return true;
        },
      );
      c.setChannel(
        'alarms',
        enabled: true,
        matchHaptics: true,
        fallbackPattern: [0, 400, 100, 400],
      );
      final matched = await c.handleMetadata({
        ...metadata(category: 'alarm'),
        'hapticPattern': [0, 100, 50, 200],
      });
      final fallback = await c.handleMetadata(
        metadata(category: 'alarm', key: 'fallback'),
      );
      expect(patterns, [
        [0, 100, 50, 200],
        [0, 400, 100, 400],
      ]);
      expect(matched.usedFallbackPattern, false);
      expect(fallback.usedFallbackPattern, true);
    },
  );
  test(
    'listener reconnect restores channels and ignores stale active entries',
    () async {
      var buzzes = 0;
      final c = controller(
        buzz: (_) async {
          buzzes++;
          return true;
        },
      );
      c.setChannel('calls', enabled: true);
      await c.listenerDisconnected();
      await c.listenerConnected([metadata(category: 'call', posted: 900000)]);
      expect(buzzes, 0);
      await c.handleMetadata(metadata(category: 'call', key: 'fresh'));
      expect(buzzes, 1);
    },
  );
  for (final reason in ['destroyed', 'permissionRevoked']) {
    test(
      '$reason clears listener state, stops delivery, and allows clean restart',
      () async {
        var buzzes = 0;
        final c = controller(
          buzz: (_) async {
            buzzes++;
            return true;
          },
        );
        c.setChannel('apps', enabled: true);
        await c.stop(reason);
        expect(c.listening, false);
        expect(c.busy, false);
        await c.handleMetadata(metadata());
        expect(buzzes, 0);
        await c.listenerConnected([]);
        await c.handleMetadata(metadata(key: 'after'));
        expect(buzzes, 1);
      },
    );
  }
  test(
    'quiet hours wrap midnight and never leak into other channels',
    () async {
      var buzzes = 0;
      final c = controller(
        selectedPolicy: {...policy(), 'minuteOfDay': 23 * 60},
        buzz: (_) async {
          buzzes++;
          return true;
        },
      );
      c.setChannel(
        'apps',
        enabled: true,
        // 8AE: the channel's own window only counts when it overrides.
        overrideQuietHours: true,
        quietStartMinute: 22 * 60,
        quietEndMinute: 7 * 60,
      );
      c.setChannel('calls', enabled: true);
      await c.handleMetadata(metadata());
      await c.handleMetadata(metadata(category: 'call', key: 'call'));
      expect(buzzes, 1);
    },
  );
}
