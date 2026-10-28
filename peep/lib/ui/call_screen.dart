import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/call_session.dart';
import '../peer.dart';
import 'peep_theme.dart';
import 'interaction_feedback.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.callState,
    required this.connected,
    required this.cameraEnabled,
    required this.microphoneEnabled,
    required this.screenShareEnabled,
    required this.localVideoViewType,
    required this.remoteVideoViews,
    required this.onAccept,
    required this.onDecline,
    required this.onEnd,
    required this.onToggleCamera,
    required this.onToggleMicrophone,
    required this.onToggleScreenShare,
    required this.onMediaSettings,
    this.startedAt,
    this.connectedAt,
    this.isGroup = false,
    this.screenSharePaused = false,
    this.screenFrameRate = 15,
    this.screenBitrateKbps = 2500,
    this.onToggleScreenSharePause,
    this.onChangeScreenSource,
    this.onScreenSettings,
  });
  final DateTime? startedAt;
  final DateTime? connectedAt;
  final bool isGroup;
  final String title;
  final String subtitle;
  final CallState callState;
  final bool connected;
  final bool cameraEnabled;
  final bool microphoneEnabled;
  final bool screenShareEnabled;
  final bool screenSharePaused;
  final int screenFrameRate;
  final int screenBitrateKbps;
  final VoidCallback? onToggleScreenSharePause;
  final VoidCallback? onChangeScreenSource;
  final VoidCallback? onScreenSettings;
  final String? localVideoViewType;
  final List<MediaView> remoteVideoViews;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onEnd;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleMicrophone;
  final VoidCallback onToggleScreenShare;
  final VoidCallback onMediaSettings;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _clock;
  String? _focusedVideo;
  bool _grid = false;
  final _zoom = TransformationController();
  late DateTime _startedAt;
  DateTime? _connectedAt;
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _startedAt = widget.startedAt ?? DateTime.now();
    _connectedAt =
        widget.connectedAt ??
        (widget.callState == CallState.active ? DateTime.now() : null);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _zoom.addListener(_zoomChanged);
  }

  @override
  void didUpdateWidget(CallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.callState == CallState.active && _connectedAt == null) {
      _connectedAt = widget.connectedAt ?? DateTime.now();
    }
    if (_focusedVideo != null &&
        !_participants.any((p) => p.viewType == _focusedVideo)) {
      _focusedVideo = null;
      _resetZoom();
    }
  }

  void _zoomChanged() {
    if (mounted) setState(() => _scale = _zoom.value.getMaxScaleOnAxis());
  }

  @override
  void dispose() {
    _clock?.cancel();
    _zoom.removeListener(_zoomChanged);
    _zoom.dispose();
    super.dispose();
  }

  List<MediaView> get _participants => [
    ...widget.remoteVideoViews,
    MediaView(
      title: 'You',
      viewType: widget.cameraEnabled || widget.screenShareEnabled
          ? widget.localVideoViewType
          : null,
    ),
  ];

  void _resetZoom() => _zoom.value = Matrix4.identity();
  void _closeVideo() {
    setState(() => _focusedVideo = null);
    _resetZoom();
  }

  void _focus(MediaView participant) {
    if (participant.viewType == null) return;
    _resetZoom();
    setState(() => _focusedVideo = participant.viewType);
  }

  void _setZoom(double scale, Size size) {
    final next = scale.clamp(1.0, 4.0);
    _zoom.value = Matrix4.identity()
      ..translateByDouble(
        size.width * (1 - next) / 2,
        size.height * (1 - next) / 2,
        0,
        1,
      )
      ..scaleByDouble(next, next, 1, 1);
  }

  void _toggleVideoFocus() {
    if (_focusedVideo != null) {
      _closeVideo();
      return;
    }
    final video = _participants.where((p) => p.viewType != null).firstOrNull;
    if (video != null) _focus(video);
  }

  void _showShortcuts() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Call shortcuts'),
      content: const Text(
        'M  ·  Mute or unmute\nV  ·  Camera on or off\nF  ·  Expand or restore video\nG  ·  Switch participant layout\nEsc  ·  Exit expanded video',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  String get _status {
    if (widget.callState == CallState.incoming) return 'Incoming call';
    if (widget.callState == CallState.outgoing) {
      return widget.isGroup ? 'Joining group call…' : 'Ringing…';
    }
    if (!widget.connected) return 'Reconnecting…';
    return 'In call · ${formatCallDuration(DateTime.now().difference(_connectedAt ?? DateTime.now()))}';
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.callState == CallState.active;
    final incoming = widget.callState == CallState.incoming;
    final participants = _participants;
    final focused = _focusedVideo == null
        ? null
        : participants.where((p) => p.viewType == _focusedVideo).firstOrNull;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && focused != null) {
          _closeVideo();
        } else if (!didPop && !active) {
          incoming ? widget.onDecline() : widget.onEnd();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closeVideo,
          if (active) ...{
            const SingleActivator(
              LogicalKeyboardKey.keyM,
              includeRepeats: false,
            ): widget.onToggleMicrophone,
            const SingleActivator(
              LogicalKeyboardKey.keyV,
              includeRepeats: false,
            ): widget.onToggleCamera,
            const SingleActivator(
              LogicalKeyboardKey.keyF,
              includeRepeats: false,
            ): _toggleVideoFocus,
            const SingleActivator(
              LogicalKeyboardKey.keyG,
              includeRepeats: false,
            ): () =>
                setState(() => _grid = !_grid),
          },
        },
        child: Focus(
          autofocus: true,
          child: Material(
            color: PeepColors.navy,
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                    child: Row(
                      children: [
                        if (focused != null)
                          IconButton(
                            tooltip: 'Exit full screen',
                            onPressed: _closeVideo,
                            icon: const Icon(
                              Icons.fullscreen_exit_rounded,
                              color: Colors.white,
                            ),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              Icons.call_outlined,
                              color: PeepColors.mint,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                focused?.title ?? widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _status,
                                style: const TextStyle(
                                  color: Color(0xffb5c8cb),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (active &&
                            focused == null &&
                            participants.length > 1)
                          IconButton(
                            tooltip: _grid ? 'Focus layout' : 'Grid layout',
                            onPressed: () => setState(() => _grid = !_grid),
                            icon: Icon(
                              _grid
                                  ? Icons.view_agenda_outlined
                                  : Icons.grid_view_rounded,
                              color: PeepColors.mint,
                            ),
                          ),
                        if (active && MediaQuery.sizeOf(context).width >= 600)
                          IconButton(
                            tooltip: 'Call shortcuts',
                            onPressed: _showShortcuts,
                            icon: const Icon(
                              Icons.keyboard_outlined,
                              color: PeepColors.mint,
                            ),
                          ),
                        IconButton(
                          tooltip: 'Call & media quality',
                          onPressed: widget.onMediaSettings,
                          icon: const Icon(
                            Icons.tune_rounded,
                            color: PeepColors.mint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (active && !widget.microphoneEnabled)
                    Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.mic_off_rounded,
                              size: 14,
                              color: PeepColors.mint,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Your microphone is off',
                              style: TextStyle(
                                color: PeepColors.mint,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (active && widget.screenShareEnabled && focused == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            widget.screenSharePaused
                                ? 'Sharing paused · no new frames'
                                : 'Sharing your screen · ${widget.screenFrameRate} fps · ${widget.screenBitrateKbps} kbps',
                            style: const TextStyle(
                              color: PeepColors.mint,
                              fontSize: 12,
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                widget.onScreenSettings ??
                                widget.onMediaSettings,
                            icon: const Icon(Icons.tune_rounded, size: 16),
                            label: const Text('Screen quality'),
                            style: TextButton.styleFrom(
                              foregroundColor: PeepColors.mint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: focused != null
                        ? _expandedVideo(focused)
                        : active
                        ? _callLayout(participants)
                        : _ringing(incoming),
                  ),
                  if (focused == null) _toolbar(active, incoming),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(
    MediaView participant, {
    bool expanded = false,
    VoidCallback? onDoubleTap,
  }) => _ParticipantTile(
    key: ValueKey('tile-${participant.title}-${participant.viewType}'),
    participant: participant,
    local: participant.title == 'You',
    screenSharing: participant.title == 'You' && widget.screenShareEnabled,
    onExpand: participant.viewType == null || expanded
        ? null
        : () => _focus(participant),
    onDoubleTap: onDoubleTap,
  );

  Widget _callLayout(List<MediaView> participants) => LayoutBuilder(
    builder: (context, constraints) {
      // A direct call gives the other person the available space, with a small
      // local preview. Groups and the explicit grid use balanced rows/columns.
      if (!_grid && !widget.isGroup && participants.length == 2) {
        final previewWidth = math.min(180.0, constraints.maxWidth * .30);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Stack(
            children: [
              Positioned.fill(child: _tile(participants.first)),
              if (participants.last.viewType != null)
                Positioned(
                  right: 12,
                  top: 12,
                  width: previewWidth,
                  height: previewWidth * .75,
                  child: _tile(participants.last),
                ),
            ],
          ),
        );
      }
      final count = participants.length;
      final width = constraints.maxWidth - 24;
      final height = math.max(100.0, constraints.maxHeight - 16);
      final columns = count <= 1
          ? 1
          : constraints.maxWidth < 600
          ? (count <= 2 && height > width ? 1 : 2)
          : math.min(count, constraints.maxWidth >= 1100 && count > 4 ? 3 : 2);
      final rows = (count / columns).ceil();
      final cellWidth = (width - (columns - 1) * 12) / columns;
      final cellHeight = math.max(130.0, (height - (rows - 1) * 12) / rows);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: cellWidth / cellHeight,
        ),
        itemCount: count,
        itemBuilder: (_, index) => _tile(participants[index]),
      );
    },
  );

  Widget _expandedVideo(MediaView participant) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return Column(
        children: [
          Expanded(
            child: ClipRect(
              child: InteractiveViewer(
                key: const ValueKey('expanded-video'),
                transformationController: _zoom,
                minScale: 1,
                maxScale: 4,
                boundaryMargin: const EdgeInsets.all(100),
                child: SizedBox(
                  width: size.width,
                  height: math.max(1, size.height - 66),
                  child: _tile(
                    participant,
                    expanded: true,
                    onDoubleTap: () => _setZoom(_scale > 1.01 ? 1 : 2, size),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                IconButton(
                  tooltip: 'Zoom out',
                  onPressed: _scale <= 1.01
                      ? null
                      : () => _setZoom(_scale - .5, size),
                  icon: const Icon(Icons.remove_rounded, color: Colors.white),
                ),
                Text(
                  '${(_scale * 100).round()}%',
                  style: const TextStyle(color: Colors.white),
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  onPressed: _scale >= 3.99
                      ? null
                      : () => _setZoom(_scale + .5, size),
                  icon: const Icon(Icons.add_rounded, color: Colors.white),
                ),
                TextButton(
                  onPressed: _resetZoom,
                  style: TextButton.styleFrom(foregroundColor: PeepColors.mint),
                  child: const Text('Reset zoom'),
                ),
                IconButton(
                  tooltip: widget.isGroup ? 'Leave call' : 'End call',
                  onPressed: widget.onEnd,
                  icon: const Icon(
                    Icons.call_end_rounded,
                    color: PeepColors.danger,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _ringing(bool incoming) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xff28464c),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Text(
              widget.isGroup ? 'GROUP CALL' : 'PRIVATE CALL',
              style: const TextStyle(
                color: PeepColors.mint,
                fontSize: 11,
                letterSpacing: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 24),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: .9, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 650),
            builder: (context, value, child) =>
                Transform.scale(scale: value, child: child),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xff41636a), width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x222ce2b3),
                    blurRadius: 36,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: PeepAvatar(label: widget.title, radius: 44),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            widget.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _status,
            style: const TextStyle(color: PeepColors.mint, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            incoming
                ? 'Accept to start talking. Your camera starts off.'
                : widget.isGroup
                ? 'Setting up audio and connecting participants.'
                : 'Waiting for ${widget.title} to answer.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xffb5c8cb), height: 1.5),
          ),
          if (!incoming) ...[
            const SizedBox(height: 10),
            Text(
              formatCallDuration(DateTime.now().difference(_startedAt)),
              style: const TextStyle(color: Color(0xff8aa6ac), fontSize: 12),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _toolbar(bool active, bool incoming) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    decoration: const BoxDecoration(
      color: Color(0xff10252b),
      border: Border(top: BorderSide(color: Color(0xff29444b))),
    ),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 12,
      children: incoming
          ? [
              _CallControl(
                icon: Icons.call_end_rounded,
                label: 'Decline',
                onPressed: widget.onDecline,
                destructive: true,
              ),
              _CallControl(
                icon: Icons.call_rounded,
                label: 'Accept',
                onPressed: widget.onAccept,
                selected: true,
              ),
            ]
          : active
          ? [
              _CallControl(
                icon: widget.microphoneEnabled
                    ? Icons.mic_rounded
                    : Icons.mic_off_rounded,
                label: widget.microphoneEnabled ? 'Mute' : 'Unmute',
                onPressed: widget.onToggleMicrophone,
                selected: widget.microphoneEnabled,
              ),
              _CallControl(
                icon: widget.cameraEnabled
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                label: widget.cameraEnabled ? 'Camera off' : 'Camera on',
                onPressed: widget.onToggleCamera,
                selected: widget.cameraEnabled,
              ),
              _CallControl(
                icon: widget.screenShareEnabled
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_outlined,
                label: widget.screenShareEnabled
                    ? 'Stop sharing'
                    : 'Share screen',
                onPressed: widget.onToggleScreenShare,
                selected: widget.screenShareEnabled,
              ),
              if (widget.screenShareEnabled) ...[
                _CallControl(
                  icon: widget.screenSharePaused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  label: widget.screenSharePaused
                      ? 'Resume sharing'
                      : 'Pause sharing',
                  onPressed: widget.onToggleScreenSharePause,
                ),
                _CallControl(
                  icon: Icons.switch_video_outlined,
                  label: 'Change source',
                  onPressed: widget.onChangeScreenSource,
                ),
              ],
              _CallControl(
                icon: Icons.call_end_rounded,
                label: widget.isGroup ? 'Leave call' : 'End call',
                onPressed: widget.onEnd,
                destructive: true,
              ),
            ]
          : [
              _CallControl(
                icon: Icons.call_end_rounded,
                label: 'Cancel',
                onPressed: widget.onEnd,
                destructive: true,
              ),
            ],
    ),
  );
}

class CallEndedScreen extends StatelessWidget {
  const CallEndedScreen({
    super.key,
    required this.summary,
    required this.onDone,
    required this.onCallAgain,
  });
  final CallSummary summary;
  final VoidCallback onDone;
  final VoidCallback? onCallAgain;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) onDone();
    },
    child: _content(context),
  );

  Widget _content(BuildContext context) => Material(
    color: PeepColors.navy,
    child: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.call_end_rounded,
                  size: 36,
                  color: PeepColors.mint,
                ),
                const SizedBox(height: 24),
                PeepAvatar(label: summary.title, radius: 44),
                const SizedBox(height: 24),
                Text(
                  summary.outcome,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  summary.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xffb5c8cb),
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  summary.connected
                      ? 'Duration · ${formatCallDuration(summary.duration)}'
                      : 'No conversation took place',
                  style: const TextStyle(color: PeepColors.mint),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onCallAgain,
                    icon: const Icon(Icons.call_rounded),
                    label: Text(summary.group ? 'Rejoin call' : 'Call again'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: onDone,
                    style: TextButton.styleFrom(
                      foregroundColor: PeepColors.mint,
                    ),
                    child: const Text('Back to chat'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    super.key,
    required this.participant,
    required this.local,
    required this.screenSharing,
    this.onExpand,
    this.onDoubleTap,
  });
  final MediaView participant;
  final bool local;
  final bool screenSharing;
  final VoidCallback? onExpand;
  final VoidCallback? onDoubleTap;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${participant.title}${screenSharing ? ' screen' : ' video'}',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: const Color(0xff223e46),
            child: participant.viewType == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PeepAvatar(
                          label: participant.title,
                          radius: local ? 20 : 30,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          local ? 'Camera off' : 'Waiting for video',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xffb5c8cb),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  )
                : IgnorePointer(
                    child: buildPlatformMediaView(
                      participant.viewType!,
                      mirror: !screenSharing,
                    ),
                  ),
          ),
          if (onExpand != null || onDoubleTap != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onExpand,
                onDoubleTap: onDoubleTap,
                child: const SizedBox.expand(),
              ),
            ),
          Positioned(
            left: 10,
            bottom: 10,
            right: 10,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${participant.title}${screenSharing ? ' · Screen' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      backgroundColor: PeepColors.navy,
                    ),
                  ),
                ),
                if (onExpand != null)
                  IconButton(
                    tooltip: 'Full screen ${participant.title}',
                    onPressed: onExpand,
                    icon: const Icon(
                      Icons.fullscreen_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _CallControl extends StatelessWidget {
  const _CallControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.destructive = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool destructive;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 80,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PeepPress(
          enabled: onPressed != null,
          child: IconButton(
            tooltip: label,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              minimumSize: const Size(54, 54),
              backgroundColor: destructive
                  ? PeepColors.danger
                  : selected
                  ? PeepColors.mint
                  : const Color(0xff2c464e),
              foregroundColor: selected && !destructive
                  ? PeepColors.navy
                  : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: AnimatedSwitcher(
              duration: peepMotion(context),
              child: Icon(icon, key: ValueKey(icon), size: 22),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xffc3d2d4), fontSize: 11),
        ),
      ],
    ),
  );
}
