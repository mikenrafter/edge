import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
void main() {
  // why: the sleep editor's cursor clears on lift; the day cursor stays (m183).
  // catches: sharing a persistent cursor policy across both screens.
  test('temporary and permanent scrubs retain differently and zoom clears', () {
    final temporary=TimelineInteraction(retention:PilotScrub.temporary);
    temporary.startScrub(120); temporary.lift(); expect(temporary.cursor,null);
    final day=TimelineInteraction(); day.startScrub(120); day.lift(); expect(day.cursor,120);
    day.zoom(); expect(day.cursor,null);
  });
  // why: only hand scrubbing auto-pins; scroll plays the copy back (m191/m192).
  // catches: programmatic focus pinning the panel or manual scrub not pinning it.
  test('pin follows hand gesture and user pin, not programmatic cursor', () {
    final s=TimelineInteraction(); s.focus(90); expect(s.pinned,false);
    s.startScrub(120); expect(s.pinned,true);
    s.lift(); expect(s.pinned,true);
    s.scroll(); expect(s.pinned,false);
    s.togglePin(); s.scroll(); expect(s.pinned,true);
  });
  // why: programmatic list scrolling during a hand scrub cannot feed back (m195).
  // catches: list scrolling overwriting the hand cursor or unpinning its readout.
  test('scroll sync is suspended throughout a hand scrub', () {
    final s=TimelineInteraction(); s.startScrub(120);
    s.scroll(); s.focus(900);
    expect(s.cursor,120); expect(s.pinned,true);
    s.lift(); s.scroll(); s.focus(900); expect(s.cursor,900);
  });
  // why: zoom must rescale to only visible real HR, with rounded padding (m181).
  // catches: using full-day extrema or inventing a scale with absent HR.
  test('visible HR ticks are rounded and absent HR has no axis', () {
    expect(visibleHeartRateTicks([180,51,58,220],start:1,end:3),[50,55,60]);
    expect(visibleHeartRateTicks([null,null],start:0,end:2),isEmpty);
  });
  // why: one selected tab defaults Pending > Saved > Discarded (m187).
  // catches: always opening Pending when no pending row exists.
  test('tab default follows availability', () {
    expect(initialTimelineTab(pending:false,saved:true),PilotTimelineTab.saved);
    expect(initialTimelineTab(pending:false,saved:false),PilotTimelineTab.discarded);
  });
}
