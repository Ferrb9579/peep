import 'package:flutter/material.dart';

import '../webrtc_peer_stub.dart'
    if (dart.library.io) '../webrtc_peer_native.dart'
    if (dart.library.html) '../webrtc_peer_web.dart';

/// A focused call surface. It deliberately replaces the chat canvas while a
/// call is ringing or active, instead of mixing media controls into messages.
class CallScreen extends StatelessWidget {
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
  });

  final String title;
  final String subtitle;
  final CallState callState;
  final bool connected;
  final bool cameraEnabled;
  final bool microphoneEnabled;
  final bool screenShareEnabled;
  final String? localVideoViewType;
  final List<MediaView> remoteVideoViews;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onEnd;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleMicrophone;
  final VoidCallback onToggleScreenShare;

  @override
  Widget build(BuildContext context) {
    final incoming = callState == CallState.incoming;
    final outgoing = callState == CallState.outgoing;
    final active = callState == CallState.active;
    final remote = remoteVideoViews.isEmpty
        ? MediaView(title: title, viewType: null)
        : remoteVideoViews.first;

    final status = incoming
        ? 'Incoming encrypted call'
        : outgoing
        ? 'Calling…'
        : 'Encrypted call';

    return Material(
      color: const Color(0xff101624),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _VideoSurface(
                title: remote.title,
                viewType: remote.viewType,
                placeholder: active
                    ? 'Waiting for ${remote.title}’s video'
                    : status,
              ),
            ),
            Positioned(
              top: 18,
              left: 20,
              right: 20,
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: const Color(0xff315dca),
                    child: Text(
                      title.isEmpty
                          ? '?'
                          : title.characters.first.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    status,
                    style: const TextStyle(
                      color: Color(0xffc8d2e6),
                      fontSize: 14,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xff8d9ab1),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (active)
              Positioned(
                top: 142,
                right: 20,
                width: 116,
                height: 154,
                child: _VideoSurface(
                  title: 'You',
                  viewType: localVideoViewType,
                  placeholder: cameraEnabled ? 'Starting camera' : 'Camera off',
                  compact: true,
                ),
              ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 30,
              child: incoming
                  ? Row(
                      children: [
                        Expanded(
                          child: _CallButton(
                            icon: Icons.call_end_rounded,
                            label: 'Decline',
                            color: const Color(0xffe5484d),
                            onPressed: onDecline,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _CallButton(
                            icon: Icons.call_rounded,
                            label: 'Accept',
                            color: const Color(0xff2faa60),
                            onPressed: onAccept,
                          ),
                        ),
                      ],
                    )
                  : active
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RoundControl(
                          icon: microphoneEnabled
                              ? Icons.mic_rounded
                              : Icons.mic_off_rounded,
                          label: microphoneEnabled ? 'Mute' : 'Unmute',
                          onPressed: onToggleMicrophone,
                        ),
                        _RoundControl(
                          icon: cameraEnabled
                              ? Icons.videocam_rounded
                              : Icons.videocam_off_rounded,
                          label: cameraEnabled ? 'Camera' : 'Video',
                          onPressed: onToggleCamera,
                        ),
                        _RoundControl(
                          icon: screenShareEnabled
                              ? Icons.stop_screen_share_rounded
                              : Icons.screen_share_rounded,
                          label: 'Share',
                          onPressed: onToggleScreenShare,
                        ),
                        _RoundControl(
                          icon: Icons.call_end_rounded,
                          label: 'End',
                          color: const Color(0xffe5484d),
                          onPressed: onEnd,
                        ),
                      ],
                    )
                  : Center(
                      child: _CallButton(
                        icon: Icons.call_end_rounded,
                        label: 'Cancel',
                        color: const Color(0xffe5484d),
                        onPressed: onEnd,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoSurface extends StatelessWidget {
  const _VideoSurface({
    required this.title,
    required this.viewType,
    required this.placeholder,
    this.compact = false,
  });
  final String title;
  final String? viewType;
  final String placeholder;
  final bool compact;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(compact ? 16 : 0),
    child: Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: const Color(0xff060b15),
          child: viewType == null
              ? Center(
                  child: Text(
                    placeholder,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color(0xffbdc8db),
                      fontSize: compact ? 11 : 15,
                    ),
                  ),
                )
              : buildPlatformMediaView(viewType!),
        ),
        Positioned(
          left: 10,
          top: 10,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color = const Color(0xff2c3649),
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: IconButton(
          onPressed: onPressed,
          color: Colors.white,
          icon: Icon(icon),
        ),
      ),
      const SizedBox(height: 5),
      Text(
        label,
        style: const TextStyle(color: Color(0xffd6deeb), fontSize: 11),
      ),
    ],
  );
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
    ),
    icon: Icon(icon),
    label: Text(label),
  );
}
