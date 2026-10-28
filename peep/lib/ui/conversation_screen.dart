import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'interaction_feedback.dart';
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
    return PeepPress(
      enabled: onPressed != null,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: const Color(0xfff2f4f7),
          disabledForegroundColor: PeepColors.subtle,
        ),
        icon: AnimatedSwitcher(
          duration: peepMotion(context),
          child: Icon(icon, key: ValueKey(icon), size: 20),
        ),
      ),
    );
  }
}

class ConversationPanel extends StatefulWidget {
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
    this.attachmentBusy = false,
  });

  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final TextEditingController messageController;
  final bool canType, canSend, canAttach, attachmentBusy;
  final VoidCallback onSend, onAttach;

  @override
  State<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<ConversationPanel> {
  final _composerFocus = FocusNode(debugLabel: 'Message composer');
  final _searchFocus = FocusNode(debugLabel: 'Search messages');
  final _search = TextEditingController();
  bool _searching = false;
  bool _awayFromLatest = false;
  int _unseen = 0;
  late int _messageCount;
  double _beforeSearch = 0;

  bool get _desktop => switch (Theme.of(context).platform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    _messageCount = widget.messages.length;
    widget.scrollController.addListener(_onScroll);
    _scrollLatest(animate: false);
  }

  @override
  void didUpdateWidget(ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
    if (widget.messages.length > _messageCount) {
      final added = widget.messages.skip(_messageCount);
      if (!_searching && (!_awayFromLatest || added.any((m) => m.isLocal))) {
        _scrollLatest();
      } else {
        _unseen += added.where((m) => !m.isLocal).length;
      }
    }
    _messageCount = widget.messages.length;
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    _composerFocus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!widget.scrollController.hasClients || _searching) return;
    final away = widget.scrollController.position.extentAfter > 100;
    if (away != _awayFromLatest || (!away && _unseen > 0)) {
      setState(() {
        _awayFromLatest = away;
        if (!away) _unseen = 0;
      });
    }
  }

  void _scrollLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.scrollController.hasClients) return;
      final scroll = widget.scrollController;
      if (animate && !MediaQuery.disableAnimationsOf(context)) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  void _toggleSearch() {
    final opening = !_searching;
    if (opening && widget.scrollController.hasClients) {
      _beforeSearch = widget.scrollController.offset;
    }
    setState(() {
      _searching = opening;
      _search.clear();
    });
    if (opening) {
      _searchFocus.requestFocus();
    } else {
      _composerFocus.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.scrollController.hasClients) return;
        widget.scrollController.jumpTo(
          _beforeSearch.clamp(
            0.0,
            widget.scrollController.position.maxScrollExtent,
          ),
        );
      });
    }
  }

  void _send() {
    final value = widget.messageController.value;
    if (!widget.canType ||
        value.text.trim().isEmpty ||
        !value.composing.isCollapsed) {
      return;
    }
    widget.onSend();
    _composerFocus.requestFocus();
  }

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (!_desktop ||
        event is! KeyDownEvent ||
        !widget.messageController.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed && widget.canType) {
        final value = widget.messageController.value;
        final selection = value.selection.isValid
            ? value.selection
            : TextSelection.collapsed(offset: value.text.length);
        final text = value.text.replaceRange(
          selection.start,
          selection.end,
          '\n',
        );
        widget.messageController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: selection.start + 1),
        );
      } else {
        _send();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _composerFocus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _quote(ChatMessage message) {
    final text = message.attachment?.name ?? message.text;
    final quote = text.split('\n').map((line) => '> $line').join('\n');
    final previous = widget.messageController.text;
    final next = '$quote\n\n$previous';
    widget.messageController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _composerFocus.requestFocus();
  }

  Widget _messageList(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return _searching && _search.text.trim().isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.search_off_rounded,
                      size: 32,
                      color: PeepColors.muted,
                    ),
                    const SizedBox(height: 12),
                    const Text('No matching messages'),
                    TextButton(
                      onPressed: () => setState(_search.clear),
                      child: const Text('Clear message search'),
                    ),
                  ],
                ),
              ),
            )
          : const _ConversationEmptyState();
    }
    return ListView.builder(
      controller: widget.scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final previous = index == 0 ? null : messages[index - 1];
        return Column(
          children: [
            if (previous == null || !_sameDay(previous.sentAt, message.sentAt))
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 20),
                child: Text(
                  _dateLabel(context, message.sentAt),
                  style: const TextStyle(
                    color: PeepColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            _MessageBubble(
              message: message,
              onQuote: widget.canType ? () => _quote(message) : null,
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = !_searching || query.isEmpty
        ? widget.messages
        : widget.messages
              .where(
                (m) =>
                    m.text.toLowerCase().contains(query) ||
                    (m.attachment?.name.toLowerCase().contains(query) ??
                        false) ||
                    (m.sender?.toLowerCase().contains(query) ?? false),
              )
              .toList();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (!_searching) {
            _toggleSearch();
          } else {
            _searchFocus.requestFocus();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          if (!_searching) {
            _toggleSearch();
          } else {
            _searchFocus.requestFocus();
          }
        },
        if (_searching)
          const SingleActivator(LogicalKeyboardKey.escape): _toggleSearch,
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: PeepColors.canvas,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lock_outline_rounded,
                      size: 13,
                      color: PeepColors.muted,
                    ),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Messages are end-to-end encrypted',
                        style: TextStyle(fontSize: 10, color: PeepColors.muted),
                      ),
                    ),
                    IconButton(
                      tooltip: _searching
                          ? 'Close message search'
                          : 'Search messages',
                      onPressed: _toggleSearch,
                      icon: Icon(
                        _searching ? Icons.close_rounded : Icons.search_rounded,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
              if (_searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search this conversation',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear message search',
                                  onPressed: () => setState(_search.clear),
                                  icon: const Icon(Icons.clear_rounded),
                                ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          '${visible.length} ${visible.length == 1 ? 'message' : 'messages'}${query.isEmpty ? '' : ' found'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: PeepColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _messageList(visible)),
                    if (!_searching && (_awayFromLatest || _unseen > 0))
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            setState(() {
                              _unseen = 0;
                              _awayFromLatest = false;
                            });
                            _scrollLatest();
                          },
                          icon: const Icon(
                            Icons.arrow_downward_rounded,
                            size: 18,
                          ),
                          label: Text(
                            _unseen > 0
                                ? '$_unseen new ${_unseen == 1 ? 'message' : 'messages'}'
                                : 'Jump to latest',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (!widget.canSend)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      widget.canType
                          ? 'Waiting for connection · messages will be queued'
                          : 'Connect to start messaging',
                      style: const TextStyle(
                        fontSize: 12,
                        color: PeepColors.warning,
                      ),
                    ),
                  ),
                ),
              const Divider(height: 1),
              ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _RoundActionButton(
                            onPressed:
                                widget.canAttach && !widget.attachmentBusy
                                ? widget.onAttach
                                : null,
                            icon: widget.attachmentBusy
                                ? Icons.hourglass_top_rounded
                                : Icons.attach_file_rounded,
                            tooltip: widget.attachmentBusy
                                ? 'Preparing attachment…'
                                : 'Attach audio or video',
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Focus(
                              onKeyEvent: _composerKey,
                              child: TextField(
                                controller: widget.messageController,
                                focusNode: _composerFocus,
                                enabled: widget.canType,
                                minLines: 1,
                                maxLines: 6,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                textInputAction: _desktop
                                    ? TextInputAction.newline
                                    : TextInputAction.send,
                                onSubmitted: (_) => _send(),
                                decoration: const InputDecoration(
                                  hintText: 'Write a message…',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: widget.messageController,
                            builder: (_, value, _) => _RoundActionButton(
                              onPressed:
                                  widget.canType &&
                                      value.text.trim().isNotEmpty &&
                                      value.composing.isCollapsed
                                  ? _send
                                  : null,
                              icon: Icons.arrow_upward_rounded,
                              tooltip: widget.canSend
                                  ? 'Send'
                                  : 'Queue until connected',
                              emphasized: true,
                            ),
                          ),
                        ],
                      ),
                      if (_desktop)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'Enter to send · Shift + Enter for a new line',
                            style: TextStyle(
                              fontSize: 10,
                              color: PeepColors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
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
  const _MessageBubble({required this.message, this.onQuote});

  final ChatMessage message;
  final VoidCallback? onQuote;

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
                  PopupMenuButton<String>(
                    tooltip: 'Message actions',
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 16,
                      color: local ? Colors.white70 : PeepColors.muted,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(40, 40),
                    ),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy message'),
                      ),
                      if (onQuote != null)
                        const PopupMenuItem(
                          value: 'quote',
                          child: Text('Quote in reply'),
                        ),
                    ],
                    onSelected: (action) async {
                      if (action == 'quote') {
                        onQuote?.call();
                        return;
                      }
                      try {
                        await Clipboard.setData(
                          ClipboardData(text: attachment?.name ?? message.text),
                        );
                        if (context.mounted) {
                          showPeepFeedback(context, 'Copied to clipboard');
                        }
                      } catch (_) {
                        if (context.mounted) {
                          showPeepFeedback(
                            context,
                            'Could not copy. Select the text to copy it.',
                          );
                        }
                      }
                    },
                  ),
                  Tooltip(
                    message: MaterialLocalizations.of(
                      context,
                    ).formatFullDate(message.sentAt),
                    child: Text(
                      _compactTime(message.sentAt),
                      style: TextStyle(
                        color: local
                            ? Colors.white.withValues(alpha: 0.72)
                            : PeepColors.subtle,
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
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
