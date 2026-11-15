// Owner's app-wide policy: stable saved identities, expanded on first launch.
// The registry covers custom disclosures; constructor calls are checked as
// Dart argument lists so a nested child's id cannot hide a missing parent id.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show accordionPrefKey;
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/dart_source_lexical.dart';
import 'support/skeleton_fixture.dart';

class _Remember extends StatefulWidget {
  const _Remember();
  @override
  State<_Remember> createState() => _RememberState();
}
class _RememberState extends State<_Remember> with RememberedExpansion<_Remember> {
  @override
  Widget build(BuildContext c) => TextButton(onPressed: () => toggleSection('cycle_shape'),
    child: Text(expandedSection('cycle_shape') ? 'expanded' : 'collapsed'));
}
void main() {
  testWidgets('every registered accordion has a saved key and an expanded default', (t) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    var count = 0;
    for (final f in dartFilesIn('lib')) {
      final source = f.readAsStringSync(), code = codeOnly(source);
      if (f.path.endsWith('/profile.dart')) continue;
      for (final m in RegExp(r'\bSettingsAccordion\s*\(').allMatches(code)) {
        count++;
        final end = closingOf(code, m.end - 1);
        final args = code.substring(m.end, end);
        // Named arguments of this call only.
        var depth = 0; final top = StringBuffer();
        for (var i = 0; i < args.length; i++) {
          final ch = args[i];
          if ('([{'.contains(ch)) depth++;
          if (depth == 0) { top.write(ch); } else { top.write(' '); }
          if (')]}'.contains(ch)) depth--;
        }
        final names = top.toString();
        expect(RegExp(r'\bid\s*:').hasMatch(names), isTrue, reason: '${f.path}:${lineOf(code,m.start)} needs a saved id');
        final initial = RegExp(r'initiallyExpanded\s*:\s*([^,\n]*)').firstMatch(names)?.group(1)?.trim();
        expect(initial == null || initial == 'true', isTrue, reason: f.path);
      }
      expect(RegExp(r'\bExpansionTile\s*\(').hasMatch(code), isFalse, reason: '${f.path} must use the saved accordion');
    }
    expect(count, greaterThan(60));
    expect(customAccordionIds, containsAll(['cycle_shape','circadian_strength','circadian_nights','food_details','ecg_details','ecg_timeline','driver:','moment-group:','sync-details']));
    await t.pumpWidget(skHost(const _Remember()));
    expect(find.text('expanded'), findsOneWidget);
    await t.tap(find.byType(TextButton)); await t.pump();
    expect(find.text('collapsed'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    // Startup cache is the first-frame oracle; do not wait for a late restore.
    final stored = await t.runAsync(() => SettingsRepository.instance.appBool(accordionPrefKey('cycle_shape')));
    expect(stored, isFalse, reason: 'the tap must persist through the actual settings writer');
    await t.pumpWidget(skHost(const _Remember()));
    expect(find.text('collapsed'), findsOneWidget);
  });
}
