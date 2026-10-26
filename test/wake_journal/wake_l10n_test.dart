// ARBs are the shipped localization input, so this is an artifact contract,
// not a source-text substitute for the widget behavior tests.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const english = {
  'wakeJournalNatural': 'Natural wake',
  'wakeJournalGradual': 'Gradual wake',
  'wakeJournalAlarm': 'Alarm',
  'wakeJournalSnooze': 'Snooze',
  'wakeJournalSnoozeStopped': 'Snooze stopped',
  'wakeJournalImUp': "I'm up",
  'wakeJournalTimeToWake': 'Time to wake: {minutes} min',
  'wakeDreamQuestion': 'How did you wake up?',
  'wakeDreamFromDream': 'From a dream',
  'wakeDreamNormally': 'Normally',
  'wakeDreamSkip': 'Skip',
};

void main() {
  for (final locale in ['en', 'de', 'es', 'fr', 'hi', 'ru', 'zh']) {
    test('P2 strings and duration placeholder are present in $locale ARB', () {
      final arb =
          jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
              as Map;
      expect(arb.keys, containsAll(english.keys));
      for (final entry in english.entries) {
        expect(arb[entry.key], isA<String>(), reason: '$locale/${entry.key}');
        expect((arb[entry.key] as String).trim(), isNotEmpty);
        if (locale == 'en') expect(arb[entry.key], entry.value);
      }
      expect(arb['wakeJournalTimeToWake'], contains('{minutes}'));
      if (locale == 'en') {
        expect(
          (arb['@wakeJournalTimeToWake'] as Map)['placeholders'],
          contains('minutes'),
        );
      }
    });
  }
}
