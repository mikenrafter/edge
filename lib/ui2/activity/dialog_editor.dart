import 'package:flutter/widgets.dart';

/// Owns transient edits for a dialog; the field controllers remain with its caller.
class DialogEditor extends StatefulWidget {
  const DialogEditor({super.key, required this.builder});
  final Widget Function(BuildContext, DialogEditorState) builder;
  @override
  State<DialogEditor> createState() => DialogEditorState();
}

class DialogEditorState extends State<DialogEditor> {
  void change(VoidCallback change) => setState(change);
  @override
  Widget build(BuildContext context) => widget.builder(context, this);
}
