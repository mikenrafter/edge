// Locale controller — the user's language override (or "System default").
// Persisted on-device via SharedPreferences, mirroring ThemeController /
// UnitsController. Null means follow the OS locale.

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

/// THE app-language resolver: the first preferred language (in the OS's
/// order) the app ships, matched by language code (none of our locales carry a
/// country or script), else English. Both the MaterialApp and text composed
/// without a BuildContext (a notification) call this, so they cannot show
/// different languages. Flutter's own default would fall back to
/// `supported.first`, whichever .arb sorts first, not English.
Locale resolveAppLocale(
  Iterable<Locale>? preferred,
  Iterable<Locale> supported,
) {
  for (final p in preferred ?? const <Locale>[]) {
    for (final s in supported) {
      if (s.languageCode == p.languageCode) return s;
    }
  }
  return const Locale('en');
}

class LocaleController extends ChangeNotifier {
  static const String _kLocale = 'locale_override'; // language code, e.g. 'es'

  String? _code;
  static LocaleController? _active;
  LocaleController._(this._code);

  /// Bind the controller actually provided to the app, not a bootstrap probe.
  void useForPresentation() {
    _active = this;
  }

  /// The app root binds its controller once per UI isolate. Creating another
  /// controller (including a late bootstrap) does not change this override.
  /// This affects presentation only; storage and calculation units stay invariant.
  static String get displayLanguageCode {
    final supported = AppLocalizations.supportedLocales
        .map((l) => l.languageCode).toSet();
    final override = _active?._code;
    if (override != null) return supported.contains(override) ? override : 'en';
    for (final locale in WidgetsBinding.instance.platformDispatcher.locales) {
      if (supported.contains(locale.languageCode)) return locale.languageCode;
    }
    return 'en';
  }

  factory LocaleController.seed(String? code) => LocaleController._(code);

  static Future<LocaleController> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kLocale);
    // A locale dropped from AppLocalizations.supportedLocales (or from a
    // stale build) has no row in the picker — fall back to system default
    // rather than showing a selection nothing matches.
    final code =
        AppLocalizations.supportedLocales.any((l) => l.languageCode == stored)
        ? stored
        : null;
    return LocaleController._(code);
  }

  @override
  void dispose() {
    // An older test/app instance must not clear a newer controller's override.
    if (identical(_active, this)) _active = null;
    super.dispose();
  }

  /// The app's strings in the language the app shows right now, for text that
  /// is composed without a BuildContext (a notification, built by the
  /// derivation engine). The wearer's override first, else the first OS
  /// preferred language the app ships, else English: the same order the app
  /// itself follows.
  static Future<AppLocalizations> currentStrings({
    List<Locale>? osLocales,
  }) async {
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
      // No (valid) override: the same resolution the app itself runs over the
      // OS's whole preferred-language list.
      code = resolveAppLocale(
        osLocales ?? PlatformDispatcher.instance.locales,
        AppLocalizations.supportedLocales,
      ).languageCode;
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
