import 'package:flutter/material.dart';

Duration peepMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 160);

void showPeepFeedback(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Adds tactile pointer feedback without taking over a button's gestures,
/// keyboard activation, focus ring, or accessibility semantics.
class PeepPress extends StatefulWidget {
  const PeepPress({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<PeepPress> createState() => _PeepPressState();
}

class _PeepPressState extends State<PeepPress> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onExit: (_) => _setPressed(false),
    child: Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: widget.enabled && _pressed ? .94 : 1,
        duration: peepMotion(context),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    ),
  );
}
