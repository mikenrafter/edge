// Screen sweep: the main screens, as the real shell builds them, checked with
// Flutter's own accessibility guidelines and the pilot's tree rules.
//
// WHY: the grammar tests pin each shared widget; this pins what a TalkBack
// user meets on a real screen, so a regression anywhere on these screens
// fails here. Guidelines that cannot pass yet are RATCHETED: the count of
// failing nodes may only go down (the number is in _ratchet, with the reason).
//
// CLAIM(A11Y-SWEEP): on Today, Sleep, Activity, Health and Sleep detail:
//  * every tappable node has a label (labeledTapTargetGuideline);
//  * no node repeats a line; at least one heading;
//  * every Pressable with a tap is reachable: a node with a tap action of its own;
//  * text contrast (textContrastGuideline) and 48 dp targets
//    (androidTapTargetGuideline) do not get worse than _ratchet.
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/a11y_tree.dart';
import 'support/apk1_harness.dart';
import 'support/pin_tz.dart';

/// Failing nodes allowed per screen and guideline, measured on the pilot
/// (2026-11-15). Lower these when a fix lands; never raise them.
///  * tap48: the 44 pt minimum (Profile, Sync now, Back, day arrows, Nerd
///    stats) under Android's 48 dp; the opt-in Pressable.minTarget is the fix
///    being piloted (A11Y-TAP48).
///  * contrast: the bottom-bar labels and inactive SubTabs pills as the
///    guideline samples them (1.6-3.8:1). The palette solves ink3 to 4.5:1, so
///    some of these may be the sampler reading the translucent bar; an
///    on-device check decides.
const _ratchet = <String, ({int tap48, int contrast})>{
  'today': (tap48: 3, contrast: 3),
  'sleep': (tap48: 5, contrast: 3),
  'activity': (tap48: 2, contrast: 5),
  'health': (tap48: 3, contrast: 4),
  'sleep_detail': (tap48: 3, contrast: 0),
};

int _failures(Evaluation e) => e.passed
    ? 0
    : e.reason!.split('\n').where((l) => l.startsWith('SemanticsNode')).length;

Future<void> _sweep(WidgetTester t, String screen) async {
  final labeled = await labeledTapTargetGuideline.evaluate(t);
  expect(labeled.passed, isTrue, reason: '$screen: ${labeled.reason}');

  expect(repeatedLines(t), isEmpty, reason: '$screen: a node reads a line twice');
  expect(headings(t), isNotEmpty, reason: '$screen: TalkBack heading navigation finds nothing');

  // Every visible Pressable with a tap owns a node with a tap action. A
  // Pressable hidden inside a labelled one would share its parent's node.
  final owners = <int, String>{};
  for (final e in find.byType(Pressable).evaluate()) {
    final w = e.widget as Pressable;
    if (w.onTap == null) continue;
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final node = t.getSemantics(find.byElementPredicate((x) => identical(x, e)));
    final d = node.getSemanticsData();
    final name = w.semanticLabel ?? d.label;
    expect(d.hasAction(SemanticsAction.tap) || d.hasFlag(SemanticsFlag.isHidden), isTrue,
        reason: '$screen: "$name" has no tap action a screen reader can use');
    final prior = owners[node.id];
    expect(prior, isNull, reason: '$screen: "$name" shares its node with "$prior"');
    owners[node.id] = name;
  }

  final tapEval = await androidTapTargetGuideline.evaluate(t);
  final contrastEval = await textContrastGuideline.evaluate(t);
  final tap48 = _failures(tapEval), contrast = _failures(contrastEval);
  // The counts and the failing nodes, for the pilot report.
  // ignore: avoid_print
  print('A11Y-SWEEP $screen tap48=$tap48 contrast=$contrast headings=${headings(t)}\n'
      '${tapEval.reason ?? ''}\n${contrastEval.reason ?? ''}');
  expect(tap48, lessThanOrEqualTo(_ratchet[screen]!.tap48));
  expect(contrast, lessThanOrEqualTo(_ratchet[screen]!.contrast));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('a11y_screens.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  for (final d in ShellDomain.values) {
    apk1Test('tab ${d.name}', (t) async {
      // hour: the greeting reads the wall clock (see ui2_a11y_pixels_test).
      await apk1Mount(t, initial: d,
          source: HomeScreen(data: apk1Home(), now: apk1Now, hour: 9));
      await _sweep(t, d.name);
    });
  }

  apk1Test('sleep detail', (t) async {
    await apk1Mount(t, page: SleepDetail(data: apk1Sleep()));
    await _sweep(t, 'sleep_detail');
  });
}
