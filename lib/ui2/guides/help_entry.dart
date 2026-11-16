import 'package:flutter/widgets.dart';
export 'guide_catalogue.dart' show GuideTopic;
import 'guide_catalogue.dart';

class HelpEntry extends StatelessWidget {
  final GuideTopic topic;
  const HelpEntry({super.key, required this.topic});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
