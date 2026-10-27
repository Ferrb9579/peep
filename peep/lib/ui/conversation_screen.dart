import 'package:flutter/material.dart';
import '../peer.dart';
import 'peep_theme.dart';

class ConversationHeader extends StatelessWidget {
  const ConversationHeader({
    super.key,
    required this.room,
    required this.peer,
    required this.statusLabel,
    required this.statusColor,
    required this.encryptionReady,
    required this.canReconnect,
    required this.onBack,
    required this.onReconnect,
    required this.onStartCall,
    required this.onMediaSettings,
    this.canCall = true,
  });
  final String room;
  final String peer;
  final String statusLabel;
  final Color statusColor;
  final bool encryptionReady;
  final bool canReconnect;
  final bool canCall;
  final VoidCallback onBack;
  final VoidCallback onReconnect;
  final VoidCallback onStartCall;
  final VoidCallback onMediaSettings;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: PeepColors.border)),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back to conversations',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded, size: 21),
        ),
        const SizedBox(width: 4),
        PeepAvatar(label: room, radius: 21),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                room,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Icon(Icons.circle, size: 6, color: statusColor),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      peer.isEmpty ? statusLabel : '$peer · $statusLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: statusColor, fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Tooltip(
                    message: encryptionReady
                        ? 'End-to-end encryption is ready'
                        : 'Preparing encryption',
                    child: Icon(
                      encryptionReady
                          ? Icons.lock_outline_rounded
                          : Icons.lock_clock_outlined,
                      color: PeepColors.muted,
                      size: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (canReconnect)
          IconButton(
            tooltip: 'Reconnect chat',
            onPressed: onReconnect,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        IconButton(
          tooltip: 'Call & media quality',
          onPressed: onMediaSettings,
          icon: const Icon(Icons.tune_rounded, size: 20),
        ),
        IconButton.filledTonal(
          tooltip: canCall ? 'Start call' : 'Connect to start a call',
          onPressed: canCall ? onStartCall : null,
          style: IconButton.styleFrom(
            backgroundColor: PeepColors.primarySoft,
            foregroundColor: PeepColors.primary,
          ),
          icon: const Icon(Icons.call_outlined, size: 20),
        ),
      ],
    ),
  );
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.onPressed,
    required this.icon,
    required this.tooltip,
    this.emphasized = false,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final background = emphasized ? PeepColors.primary : PeepColors.canvas;
    final foreground = emphasized ? Colors.white : PeepColors.muted;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: const Color(0xfff2f4f7),
        disabledForegroundColor: PeepColors.subtle,
      ),
      icon: Icon(icon, size: 20),
    );
  }
}

class ConversationPanel extends StatelessWidget {
  const ConversationPanel({
    super.key,
    required this.messages,
    required this.scrollController,
    required this.messageController,
    required this.canType,
    required this.canSend,
    required this.canAttach,
    required this.onSend,
    required this.onAttach,
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final TextEditingController messageController;
  final bool canType;
  final bool canSend;
  final bool canAttach;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: PeepColors.canvas),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 42,
            color: PeepColors.canvas,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Expanded(child: Divider()),
                const SizedBox(width: 10),
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: PeepColors.subtle,
                ),
                const SizedBox(width: 5),
                Text(
                  'Messages are end-to-end encrypted',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontSize: 10),
                ),
                const SizedBox(width: 10),
                const Expanded(child: Divider()),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? const _ConversationEmptyState()
                : ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final previous = index == 0 ? null : messages[index - 1];
                      final startsDay =
                          previous == null ||
                          !_sameDay(previous.sentAt, message.sentAt);
                      return Column(
                        children: [
                          if (startsDay)
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 4,
                                bottom: 20,
                              ),
                              child: Text(
                                _dateLabel(context, message.sentAt),
                                style: const TextStyle(
                                  color: PeepColors.muted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          _MessageBubble(message: message),
                        ],
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _RoundActionButton(
                  onPressed: canAttach ? onAttach : null,
                  icon: Icons.attach_file_rounded,
                  tooltip: 'Attach audio or video',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: PeepColors.canvas,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TextField(
                      controller: messageController,
                      enabled: canType,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: canType
                          ? (_) {
                              if (messageController.text.trim().isNotEmpty) {
                                onSend();
                              }
                            }
                          : null,
                      decoration: const InputDecoration(
                        hintText: 'Write a message…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: messageController,
                  builder: (_, value, _) => _RoundActionButton(
                    onPressed: canType && value.text.trim().isNotEmpty
                        ? onSend
                        : null,
                    icon: Icons.arrow_upward_rounded,
                    tooltip: canSend ? 'Send' : 'Queue until connected',
                    emphasized: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationEmptyState extends StatelessWidget {
  const _ConversationEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: PeepColors.primarySoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.waving_hand_rounded,
                color: PeepColors.primary,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text('Say hello', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'This is the beginning of your private conversation.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: PeepColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final local = message.isLocal;
    final attachment = message.attachment;
    final radius = local
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(5),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          );

    return Align(
      alignment: local ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
          decoration: BoxDecoration(
            color: local ? PeepColors.primary : Colors.white,
            borderRadius: radius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!local && message.sender?.isNotEmpty == true) ...[
                Text(
                  message.sender!,
                  style: const TextStyle(
                    color: PeepColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              if (attachment == null)
                SelectableText(
                  message.text,
                  style: TextStyle(
                    color: local ? Colors.white : PeepColors.ink,
                    fontSize: 14,
                    height: 1.4,
                  ),
                )
              else
                _AttachmentBubble(attachment: attachment, isLocal: local),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    _compactTime(message.sentAt),
                    style: TextStyle(
                      color: local
                          ? Colors.white.withValues(alpha: 0.72)
                          : PeepColors.subtle,
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentBubble extends StatelessWidget {
  const _AttachmentBubble({required this.attachment, required this.isLocal});

  final AttachmentData attachment;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final textColor = isLocal ? Colors.white : const Color(0xff111827);
    final mediaHeight = attachment.isVideo ? 220.0 : 48.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              attachment.isVideo
                  ? Icons.movie_outlined
                  : Icons.audio_file_outlined,
              size: 20,
              color: textColor,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                attachment.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${attachment.mimeType} • ${_formatBytes(attachment.size)}',
          style: TextStyle(color: textColor.withValues(alpha: 0.82)),
        ),
        if (attachment.viewType != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 460,
              height: mediaHeight,
              child: buildPlatformMediaView(attachment.viewType!),
            ),
          ),
        ],
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }
}

String _compactTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

bool _sameDay(DateTime first, DateTime second) =>
    first.year == second.year &&
    first.month == second.month &&
    first.day == second.day;
String _dateLabel(BuildContext context, DateTime time) {
  final now = DateTime.now();
  if (_sameDay(now, time)) return 'Today';
  if (_sameDay(now.subtract(const Duration(days: 1)), time)) return 'Yesterday';
  return MaterialLocalizations.of(context).formatMediumDate(time);
}
