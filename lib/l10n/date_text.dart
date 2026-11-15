import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'app_localizations.dart';

bool _dateDataLoaded = false;

/// Also works in standalone share cards without the app's localization loader.
String localizedDate(
  DateTime date,
  String code, {
  bool weekday = false,
  bool withDayOfWeek = false,
  String? pattern,
}) {
  if (!_dateDataLoaded) {
    // The bundled local initializer installs symbols and patterns synchronously,
    // then returns an already-completed Future; it performs no I/O.
    unawaited(initializeDateFormatting());
    _dateDataLoaded = true;
  }
  final locale = DateFormat.localeExists(code) ? code : 'en';
  if (pattern != null) return DateFormat(pattern, locale).format(date);
  // The locale's own order and punctuation for weekday, day, month and year.
  if (withDayOfWeek) return DateFormat.yMMMEd(locale).format(date);
  if (weekday) {
    final result = DateFormat('EEEE, d MMMM', locale).format(date);
    return '${result[0].toUpperCase()}${result.substring(1)}';
  }
  return DateFormat.yMMMd(locale).format(date);
}

/// Weekday, day, month and time in the locale's own order, e.g. "Thu 12 Nov
/// 08:14". No year: it is the moment something happened, not a record's date.
/// [time] is the time of day already formatted (the app passes its 12/24 h
/// formatter's text); the default is the locale's own 24-hour time.
String localizedDateTime(DateTime moment, String code, {String? time}) {
  localizedDate(moment, code); // makes sure the date symbols are loaded
  final locale = DateFormat.localeExists(code) ? code : 'en';
  if (time == null) return DateFormat.MMMEd(locale).add_Hm().format(moment);
  return '${DateFormat.MMMEd(locale).format(moment)} $time';
}

String displayDate(BuildContext context, DateTime date) => localizedDate(
  date,
  AppLocalizations.of(context)?.localeName ??
      Localizations.localeOf(context).languageCode,
);

String displayDay(String? day, AppLocalizations? l, {bool weekday = false}) {
  final date = day == null ? null : DateTime.tryParse(day);
  return date == null
      ? day ?? ''
      : localizedDate(date, l?.localeName ?? 'en', weekday: weekday);
}
