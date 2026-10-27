import '../peer.dart';

String formatCallDuration(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

class CallSummary {
  const CallSummary({
    required this.title,
    required this.group,
    required this.outgoing,
    required this.startedAt,
    required this.duration,
    required this.connected,
    required this.outcome,
  });

  final String title;
  final bool group;
  final bool outgoing;
  final DateTime startedAt;
  final Duration duration;
  final bool connected;
  final String outcome;
}

/// Presentation history follows transport transitions, including remote hang-up.
/// The clock is injectable so ringing time never gets counted as call duration.
class CallSessionTracker {
  CallSessionTracker({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  CallState _state = CallState.idle;
  DateTime? startedAt;
  DateTime? connectedAt;
  String _title = '';
  bool _group = false;
  bool _outgoing = true;
  String? endOutcome;
  CallSummary? summary;

  void update(CallState state, {required String title, required bool group}) {
    if (_state == CallState.idle && state != CallState.idle) {
      summary = null;
      endOutcome = null;
      startedAt = _now();
      connectedAt = null;
      _title = title;
      _group = group;
      _outgoing = state != CallState.incoming;
    }
    if (state == CallState.active && connectedAt == null) {
      connectedAt = _now();
    }
    if (_state != CallState.idle && state == CallState.idle) {
      summary = CallSummary(
        title: _title,
        group: _group,
        outgoing: _outgoing,
        startedAt: startedAt!,
        connected: connectedAt != null,
        duration: connectedAt == null
            ? Duration.zero
            : _now().difference(connectedAt!),
        outcome:
            endOutcome ??
            (connectedAt == null
                ? (_outgoing ? 'Call not connected' : 'Missed call')
                : 'Call ended'),
      );
    }
    _state = state;
  }

  void reset() {
    _state = CallState.idle;
    startedAt = null;
    connectedAt = null;
    endOutcome = null;
    summary = null;
  }
}
