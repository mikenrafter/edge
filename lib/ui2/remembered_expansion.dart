// Custom disclosure rows share the same startup cache and durable preference
// keys as SettingsAccordion. State belongs to the screen; persistence belongs
// to SettingsRepository. A missing preference always means expanded.
import 'dart:async';
import 'package:flutter/widgets.dart';
import '../settings/settings_repository.dart';
import '../state/prefs.dart';
import 'profile/profile.dart' show accordionPrefKey;

const customAccordionIds = {
  'cycle_shape', 'circadian_strength', 'circadian_nights', 'food_details',
  'guide_missing_help', 'ecg_details', 'ecg_timeline', 'driver:',
  'sync-details',
};

mixin RememberedExpansion<T extends StatefulWidget> on State<T> {
  final _expansion = <String, bool>{};
  bool expandedSection(String id) =>
      _expansion[id] ?? Prefs.getBool(accordionPrefKey(id), true);
  void setSectionExpanded(String id, bool expanded) {
    setState(() => _expansion[id] = expanded);
    unawaited(_saveExpanded(id, expanded));
  }
  void toggleSection(String id) => setSectionExpanded(id, !expandedSection(id));
  Future<void> _saveExpanded(String id, bool expanded) async {
    try {
      await SettingsRepository.instance.update(
        (d) => d.setBool(accordionPrefKey(id), expanded), sections: const {});
    } catch (_) {
      // The local choice remains usable when preferences cannot be written.
    }
  }
}
