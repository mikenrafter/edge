// Locale controller — the user's language override (or "System default").
// Persisted on-device via SharedPreferences, mirroring ThemeController /
// UnitsController. Null means follow the OS locale.

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

class LocaleController extends ChangeNotifier {
  static const String _kLocale = 'locale_override'; // language code, e.g. 'es'

  String? _code;
  LocaleController._(this._code);

  factory LocaleController.seed(String? code) => LocaleController._(code);

  static Future<LocaleController> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kLocale);
    // A locale dropped from AppLocalizations.supportedLocales (or from a
    // stale build) has no row in the picker — fall back to system default
    // rather than showing a selection nothing matches.
    final code = AppLocalizations.supportedLocales
            .any((l) => l.languageCode == stored)
        ? stored
        : null;
    return LocaleController._(code);
  }

  /// The app's strings in the language the app shows right now, for text that
  /// is composed without a BuildContext (a notification, built by the
  /// derivation engine). The wearer's override first, else the OS language,
  /// else English: the same order the app itself follows.
  static Future<AppLocalizations> currentStrings() async {
    final supported = {
      for (final l in AppLocalizations.supportedLocales) l.languageCode,
    };
    String? code;
    try {
      code = (await SharedPreferences.getInstance()).getString(_kLocale);
    } catch (_) {
      // No preferences (a bare test host): follow the OS.
    }
    if (!supported.contains(code)) {
      final os = PlatformDispatcher.instance.locale.languageCode;
      code = supported.contains(os) ? os : 'en';
    }
    return lookupAppLocalizations(Locale(code!));
  }

  /// null = system default.
  String? get code => _code;
  Locale? get locale => _code == null ? null : Locale(_code!);

  Future<void> setCode(String? code) async {
    if (_code == code) return;
    _code = code;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (code == null) {
      await prefs.remove(_kLocale);
    } else {
      await prefs.setString(_kLocale, code);
    }
  }
}
