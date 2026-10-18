// The in-app double-tap action AppState owns: mark a moment (a
// read-modify-write of the day's journal through the repository seam). The tap
// travels the real engine path. ("Log water" is retired in the merged
// dispatcher: it runs as Mark a moment.)

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/device_action.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_actions.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ActionChannel channel;
  late HapticSpy haptics;
  setUpAll(() => gestureDbSetUp(_db));
  tearDownAll(() => gestureDbTearDown(_db));
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    channel = ActionChannel();
    haptics = HapticSpy();
    // Once-ever gesture claims (keyed by strap time and sub-second) must not
    // leak from one test's taps into the next.
    await (await LocalDb.instance).delete('notif_fired');
  });
  tearDown(() {
    channel.dispose();
    haptics.dispose();
    BleEngine.resetBandClaimForTest();
  });

  Future<(GestureRig, FakeJournalRepo)> newRig(DeviceAction a) async {
    final rig = GestureRig(mg: false);
    addTearDown(rig.dispose);
    final repo = FakeJournalRepo();
    rig.app.repo = repo;
    await rig.map(a);
    return (rig, repo);
  }

  /// One tap, a distinct one (its own strap time and sub-second).
  Future<void> tap(GestureRig rig) async {
    rig.advance(const Duration(seconds: 3));
    rig.doubleTap();
  }

  /// Let a finished action release its latch (it clears in a `finally` right
  /// after the haptic), so a following tap is judged on the latch alone.
  Future<void> latchSettles() => settleMs(30);

  group('mark moment', () {
    final stamp = RegExp(r'^moment \d\d:\d\d$');

    test('stamps a timestamped tag on today with an empty note when the day '
        'has no journal yet', () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      await tap(rig);
      await until(() => repo.journalPosts.isNotEmpty);
      await until(() => haptics.calls.isNotEmpty);
      final post = repo.journalPosts.single;
      expect(post.date, todayLabel());
      expect(post.tags, hasLength(1));
      expect(post.tags.single, matches(stamp));
      expect(post.note, '');
      // The merged handler reads the whole journal: a replayed tap can belong
      // to a day older than any fixed window.
      expect(repo.calls.first, 'getJournal:all');
      expect(haptics.calls, ['HapticFeedbackType.mediumImpact']);
    });

    test('existing tags and note survive, in order; other days are not '
        'touched', () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      repo.entries.addAll([
        {'date': '2000-01-01', 'tags': ['old'], 'note': 'another day'},
        {'date': todayLabel(), 'tags': ['gym', 'sauna'], 'note': 'felt good'},
      ]);
      await tap(rig);
      await until(() => repo.journalPosts.isNotEmpty);
      final post = repo.journalPosts.single;
      expect(post.date, todayLabel());
      expect(post.tags.take(2), ['gym', 'sauna']);
      expect(post.tags, hasLength(3));
      expect(post.tags.last, matches(stamp));
      expect(post.note, 'felt good');
    });

    test('a repository with no journal starts the day clean and still posts',
        () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      // Only a seam without a journal starts clean: any other read failure
      // propagates (posting would replace the day with this one tag).
      repo.getJournalThrows = UnimplementedError('no journal');
      await tap(rig);
      await until(() => repo.journalPosts.isNotEmpty);
      expect(repo.journalPosts.single.tags.single, matches(stamp));
      expect(repo.journalPosts.single.note, '');
    });

    test('a failing post is logged, plays no haptic, and the next tap works',
        () async {
      final (rig, repo) = await newRig(DeviceAction.markMoment);
      repo.postJournalThrows = StateError('write blew up');
      await tap(rig);
      await until(() => rig.app.logLines
          .any((l) => l.startsWith('[gesture] mark_moment failed')));
      expect(haptics.calls, isEmpty);
      await latchSettles();
      repo.postJournalThrows = null;
      await tap(rig);
      await until(() => repo.journalPosts.length == 1);
    });

    test('without a repository the tap does nothing', () async {
      final rig = GestureRig(mg: false);
      addTearDown(rig.dispose);
      await rig.map(DeviceAction.markMoment);
      rig.app.repo = null;
      await tap(rig);
      await settleMs(100);
      expect(haptics.calls, isEmpty);
    });
  });
}
