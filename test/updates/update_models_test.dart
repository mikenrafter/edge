// WHY: a notification payload is attacker-shaped input (a stale notification,
// another app's intent). It may carry only a checked source/tag pair; the page
// is rebuilt locally from two fixed repositories, so no payload can name a URL.
// Proves CLAIM(release-check-page-only).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/tap_router.dart';
import 'package:openstrap_edge/sync/update_models.dart';

void main() {
  const official = 'https://github.com/OpenStrap/edge/releases/tag/v0.11.4';
  const fork = 'https://github.com/mikenrafter/edge/releases/tag/next-2026.11.15';

  // catches: a route parser that accepts any `source`/`tag` text, or one that
  // returns the payload instead of rebuilding the page.
  test('a typed route round-trips to exactly the canonical page', () {
    expect(
      ReleaseRoute.parse(releaseRoute(ReleaseSource.official, 'v0.11.4'))
          ?.toString(),
      official,
    );
    expect(
      ReleaseRoute.parse(releaseRoute(ReleaseSource.fork, 'next-2026.11.15'))
          ?.toString(),
      fork,
    );
    final candidate = ReleaseCandidate(
      source: ReleaseSource.fork,
      id: 5,
      tag: 'next-2026.11.15',
      asset: 'openstrap-edge-next-2026.11.15-dev-profile.apk',
      prerelease: true,
    );
    expect(ReleaseRoute.parse(candidate.route), candidate.page);
  });

  // catches: URL, scheme, extra-parameter and wrong-grammar payloads.
  for (final route in <String?>[
    null,
    '',
    official,
    'javascript:alert(1)',
    '/release',
    '/release?source=official',
    '/release?tag=v0.11.4',
    '/release?source=evil&tag=v0.11.4',
    '/release?source=official&tag=next-2026.11.15', // fork tag, official source
    '/release?source=fork&tag=v0.11.4', // official tag, fork source
    '/release?source=official&tag=v0.11.4&url=https%3A%2F%2Fevil.test',
    '/release?source=official&tag=v0.11.4&source=fork',
    '/release?source=official&tag=%2e%2e',
    '/release?source=official&tag=v0.11.4%2F..%2F..',
    '/today?source=official&tag=v0.11.4',
    '//evil.test/release?source=official&tag=v0.11.4',
    'https://evil.test/release?source=official&tag=v0.11.4',
    '/release/../today?source=official&tag=v0.11.4',
  ]) {
    test('refuses payload ${route ?? 'null'}', () {
      expect(ReleaseRoute.parse(route), isNull);
    });
  }

  // WHY: foreground and cold-launch taps share resolveTapRoute; the browser is
  // opened only from a validated page, and nothing else navigates.
  // catches: an early `https:` bypass for arbitrary URLs, or opening the page
  // while also pushing a screen.
  test('resolveTapRoute yields a validated release page and no screen', () {
    final target = resolveTapRoute(
      releaseRoute(ReleaseSource.official, 'v0.11.4'),
    );
    expect(target.release?.toString(), official);
    expect(target.screen, isNull);
    for (final bad in [
      official,
      'https://evil.test/a.apk',
      '/release?source=official&tag=nope',
    ]) {
      final t = resolveTapRoute(bad);
      expect(t.release, isNull, reason: bad);
      expect(t.screen, isNull, reason: bad);
      expect(t.tab, 0, reason: bad);
    }
  });
}
