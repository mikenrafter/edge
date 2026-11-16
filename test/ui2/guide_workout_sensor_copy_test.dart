import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide_copy.dart';

void main() {
  // WHY: a disconnected band does not prevent another connected HR sensor
  // supplying workout heart rate. These reviewed translations scope the claim.
  // catches: the former blanket no-heart-rate-without-band statement.
  const expected = {
    "en": "You can still start a session. A disconnected band supplies no heart rate, but another connected heart-rate sensor can.",
    "de": "Du kannst trotzdem ein Training starten. Ein nicht verbundenes Band liefert keine Herzfrequenz, ein anderer verbundener Herzfrequenzsensor kann sie aber liefern.",
    "es": "Aun así puedes empezar una sesión. Una banda desconectada no aporta frecuencia cardíaca, pero otro sensor de frecuencia cardíaca conectado sí puede hacerlo.",
    "fr": "Vous pouvez quand même démarrer une séance. Un bracelet déconnecté ne fournit pas de fréquence cardiaque, mais un autre capteur de fréquence cardiaque connecté peut le faire.",
    "hi": "फिर भी आप सेशन शुरू कर सकते हैं। डिस्कनेक्ट किया हुआ बैंड हृदय गति नहीं देता, लेकिन कोई दूसरा कनेक्ट किया हुआ हृदय गति सेंसर दे सकता है।",
    "ru": "Тренировку всё равно можно начать. Отключённый браслет не передаёт пульс, но другой подключённый датчик пульса может его передавать.",
    "zh": "你仍然可以开始训练。未连接的手环不会提供心率，但其他已连接的心率传感器可以。",
  };
  for (final entry in expected.entries) {
    test('${entry.key}: disconnected band note allows another HR sensor', () {
      expect(GuideCopy.startWorkoutFooter0Body.of(lookupAppLocalizations(Locale(entry.key))), entry.value);
    });
  }
}
