import 'package:flutter/widgets.dart';

/// Drafts live only in this signed-in session, never in plaintext preferences.
class ConversationDrafts {
  final Map<String, TextEditingValue> _drafts = {};
  String? _active;

  void open(String? conversation, TextEditingController controller) {
    if (_active == conversation) return;
    final active = _active;
    if (active != null) {
      if (controller.text.isEmpty) {
        _drafts.remove(active);
      } else {
        _drafts[active] = controller.value.copyWith(composing: TextRange.empty);
      }
    }
    _active = conversation;
    controller.value = _drafts[conversation] ?? TextEditingValue.empty;
  }

  void clear(TextEditingController controller) {
    _drafts.clear();
    _active = null;
    controller.clear();
  }
}
