import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../theme.dart';
import 'timeline_filter.dart';

class TimelineFilterButton extends StatelessWidget {
  const TimelineFilterButton({super.key, required this.filter});
  final TimelineFilter filter;

  Future<void> _show(BuildContext context) async {
    final l =
        (AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en')));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: filter,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(S.x4),
                  child: Text(l.dayActivitiesShow, style: F.head),
                ),
                for (final kind in DayTimelineKind.values)
                  CheckboxListTile(
                    key: ValueKey('timeline-kind:${kind.name}'),
                    value: filter.kinds.contains(kind),
                    title: Text(switch (kind) {
                      DayTimelineKind.pending => l.dayActivitiesPending,
                      DayTimelineKind.saved => l.dayActivitiesSaved,
                      DayTimelineKind.discarded => l.dayActivitiesDiscarded,
                    }),
                    subtitle: Text(switch (kind) {
                      DayTimelineKind.pending => l.dayActivitiesPendingDetail,
                      DayTimelineKind.saved => l.dayActivitiesSavedDetail,
                      DayTimelineKind.discarded =>
                        l.dayActivitiesDiscardedDetail,
                    }),
                    onChanged:
                        filter.kinds.length == 1 && filter.kinds.contains(kind)
                        ? null
                        : (on) {
                            final kinds = {...filter.kinds};
                            if (on == true) {
                              kinds.add(kind);
                            } else {
                              kinds.remove(kind);
                            }
                            filter.setKinds(kinds);
                          },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l =
        (AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en')));
    return ListenableBuilder(
      listenable: filter,
      builder: (context, _) => Semantics(
        label: l.dayActivitiesFilterCount(filter.kinds.length),
        excludeSemantics: true,
        button: true,
        onTap: () => _show(context),
        child: TextButton(
          key: const ValueKey('timeline-filter'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => _show(context),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(l.dayActivitiesFilter)),
              const SizedBox(width: S.x1),
              Container(
                padding: const EdgeInsets.all(S.x1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: P.of(context).card2,
                ),
                child: Text('${filter.kinds.length}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
