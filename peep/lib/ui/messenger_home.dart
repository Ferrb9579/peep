import 'package:flutter/material.dart';

import '../webrtc_peer_stub.dart'
    if (dart.library.io) '../webrtc_peer_native.dart'
    if (dart.library.html) '../webrtc_peer_web.dart';

/// View model for one direct-conversation row in the unified inbox.
class ChatListEntry {
  const ChatListEntry({
    required this.contactUsername,
    required this.lastText,
    required this.updatedAt,
    required this.unreadCount,
  });

  final String contactUsername;
  final String lastText;
  final DateTime updatedAt;
  final int unreadCount;
}

/// A lightweight local record for the Calls tab. Call transport remains owned
/// by the application controller.
class CallHistoryEntry {
  const CallHistoryEntry({
    required this.title,
    required this.subtitle,
    required this.startedAt,
    required this.outgoing,
  });

  final String title;
  final String subtitle;
  final DateTime startedAt;
  final bool outgoing;
}

class MessengerHome extends StatefulWidget {
  const MessengerHome({
    super.key,
    required this.signalingController,
    required this.contactController,
    required this.groupNameController,
    required this.groupMembersController,
    required this.session,
    required this.chatEntries,
    required this.groups,
    required this.callHistory,
    required this.connecting,
    required this.groupsBusy,
    required this.onConnect,
    required this.onOpenChatEntry,
    required this.onCreateGroup,
    required this.onOpenGroup,
    required this.onRefreshGroups,
    required this.onSignOut,
    required this.logs,
  });

  final TextEditingController signalingController;
  final TextEditingController contactController;
  final TextEditingController groupNameController;
  final TextEditingController groupMembersController;
  final AuthSession session;
  final List<ChatListEntry> chatEntries;
  final List<GroupSummary> groups;
  final List<CallHistoryEntry> callHistory;
  final bool connecting;
  final bool groupsBusy;
  final VoidCallback onConnect;
  final ValueChanged<ChatListEntry> onOpenChatEntry;
  final ValueChanged<GroupSummary> onOpenGroup;
  final VoidCallback onCreateGroup;
  final VoidCallback onRefreshGroups;
  final VoidCallback onSignOut;
  final List<String> logs;

  @override
  State<MessengerHome> createState() => _MessengerHomeState();
}

class _MessengerHomeState extends State<MessengerHome> {
  static const _primary = Color(0xff3a76f0);
  static const _ink = Color(0xff1d2533);
  int _tabIndex = 0;

  void _showNewChat() {
    showDialog<void>(
      context: context,
      builder: (context) => _MessengerDialog(
        title: 'New message',
        actionLabel: widget.connecting ? 'Connecting…' : 'Next',
        enabled: !widget.connecting,
        onAction: () {
          Navigator.of(context).pop();
          widget.onConnect();
        },
        child: TextField(
          controller: widget.contactController,
          autofocus: true,
          enabled: !widget.connecting,
          textInputAction: TextInputAction.done,
          onSubmitted: widget.connecting
              ? null
              : (_) {
                  Navigator.of(context).pop();
                  widget.onConnect();
                },
          decoration: const InputDecoration(
            labelText: 'Username',
            hintText: 'e.g. alex',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
      ),
    );
  }

  void _showNewGroup() {
    showDialog<void>(
      context: context,
      builder: (context) => _MessengerDialog(
        title: 'New group',
        actionLabel: widget.groupsBusy ? 'Creating…' : 'Create',
        enabled: !widget.groupsBusy,
        onAction: () {
          Navigator.of(context).pop();
          widget.onCreateGroup();
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: widget.groupNameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: widget.groupMembersController,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Member usernames',
                hintText: 'alex, maya, sam',
                helperText: 'Separate usernames with commas',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showConnectionSettings() {
    showDialog<void>(
      context: context,
      builder: (context) => _MessengerDialog(
        title: 'Connection settings',
        actionLabel: 'Done',
        onAction: () => Navigator.of(context).pop(),
        child: TextField(
          controller: widget.signalingController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Signaling server URL',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
      ),
    );
  }

  void _showComposeSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.person_add_alt_1),
                ),
                title: const Text('New message'),
                subtitle: const Text('Start a private conversation'),
                onTap: widget.connecting
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        Future<void>.delayed(Duration.zero, _showNewChat);
                      },
              ),
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.group_add)),
                title: const Text('New group'),
                subtitle: const Text('Create an encrypted group'),
                onTap: widget.groupsBusy
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        Future<void>.delayed(Duration.zero, _showNewGroup);
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inbox() {
    final empty = widget.chatEntries.isEmpty && widget.groups.isEmpty;
    return RefreshIndicator(
      onRefresh: () async => widget.onRefreshGroups(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 104),
        children: [
          if (widget.connecting)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (empty)
            const Padding(
              padding: EdgeInsets.only(top: 96),
              child: _MessengerEmpty(
                icon: Icons.markunread_outlined,
                title: 'No messages yet',
                message: 'Start a new message to begin a private conversation.',
              ),
            ),
          for (final entry in widget.chatEntries)
            _ConversationTile.direct(
              entry: entry,
              enabled: !widget.connecting,
              onTap: () => widget.onOpenChatEntry(entry),
            ),
          for (final group in widget.groups)
            _ConversationTile.group(
              group: group,
              enabled: !widget.groupsBusy,
              onTap: () => widget.onOpenGroup(group),
            ),
          if (widget.groupsBusy && widget.groups.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _calls() {
    if (widget.callHistory.isEmpty) {
      return const _MessengerEmpty(
        icon: Icons.call_outlined,
        title: 'No calls yet',
        message: 'Calls you make or receive will appear here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: widget.callHistory.length,
      separatorBuilder: (_, _) => const Divider(indent: 72),
      itemBuilder: (context, index) {
        final call = widget.callHistory[index];
        return ListTile(
          leading: _Avatar(label: call.title),
          title: Text(
            call.title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text('${call.subtitle} • ${_compactTime(call.startedAt)}'),
          trailing: Icon(
            call.outgoing
                ? Icons.call_made_rounded
                : Icons.call_received_rounded,
            color: _primary,
          ),
        );
      },
    );
  }

  Widget _settings() => ListView(
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
    children: [
      ListTile(
        leading: _Avatar(label: widget.session.username),
        title: Text(
          '@${widget.session.username}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(widget.session.email),
      ),
      const Divider(),
      const _SettingsTile(icon: Icons.person_outline, title: 'Account'),
      const _SettingsTile(icon: Icons.lock_outline, title: 'Privacy'),
      const _SettingsTile(icon: Icons.palette_outlined, title: 'Appearance'),
      _SettingsTile(
        icon: Icons.hub_outlined,
        title: 'Connection settings',
        onTap: _showConnectionSettings,
      ),
      _SettingsTile(
        icon: Icons.terminal_rounded,
        title: 'Connection activity',
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => _MessengerDialog(
            title: 'Connection activity',
            actionLabel: 'Done',
            onAction: () => Navigator.of(context).pop(),
            child: SizedBox(
              height: 220,
              child: ListView(
                children: widget.logs.reversed
                    .map(
                      (log) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(log, style: const TextStyle(fontSize: 12)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ),
      ),
      const Divider(),
      _SettingsTile(
        icon: Icons.logout_rounded,
        title: 'Sign out',
        destructive: true,
        onTap: widget.connecting ? null : widget.onSignOut,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final titles = ['Chats', 'Calls', 'Settings'];
    final body = switch (_tabIndex) {
      0 => _inbox(),
      1 => _calls(),
      _ => _settings(),
    };
    return Material(
      color: const Color(0xfff7f7f8),
      child: Column(
        children: [
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: Colors.white,
            child: Row(
              children: [
                Text(
                  titles[_tabIndex],
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                if (_tabIndex == 0)
                  IconButton(
                    tooltip: 'New message',
                    onPressed: widget.connecting ? null : _showNewChat,
                    icon: const Icon(Icons.edit_square),
                  ),
                IconButton(
                  tooltip: 'More options',
                  onPressed: _showComposeSheet,
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
          NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (index) => setState(() => _tabIndex = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Chats',
              ),
              NavigationDestination(
                icon: Icon(Icons.call_outlined),
                selectedIcon: Icon(Icons.call),
                label: 'Calls',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessengerDialog extends StatelessWidget {
  const _MessengerDialog({
    required this.title,
    required this.actionLabel,
    required this.onAction,
    required this.child,
    this.enabled = true,
  });
  final String title;
  final String actionLabel;
  final VoidCallback onAction;
  final Widget child;
  final bool enabled;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: child,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: enabled ? onAction : null,
        child: Text(actionLabel),
      ),
    ],
  );
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile.direct({
    required this.entry,
    required this.enabled,
    required this.onTap,
  }) : group = null;
  const _ConversationTile.group({
    required this.group,
    required this.enabled,
    required this.onTap,
  }) : entry = null;
  final ChatListEntry? entry;
  final GroupSummary? group;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final direct = entry != null;
    final title = direct ? entry!.contactUsername : group!.name;
    final subtitle = direct
        ? entry!.lastText
        : '${group!.members.length} members • Encrypted group';
    final unread = direct ? entry!.unreadCount : 0;
    return Material(
      color: unread > 0 ? const Color(0xffeef4ff) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              direct
                  ? _Avatar(label: title, unread: unread > 0)
                  : const CircleAvatar(
                      backgroundColor: Color(0xffe9f8ef),
                      foregroundColor: Color(0xff228a50),
                      child: Icon(Icons.group),
                    ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: unread > 0
                            ? FontWeight.w800
                            : FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff687386),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (direct) ...[
                Text(
                  _compactTime(entry!.updatedAt),
                  style: const TextStyle(
                    color: Color(0xff687386),
                    fontSize: 11,
                  ),
                ),
                if (unread > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: _MessengerHomeState._primary,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$unread',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label, this.unread = false});
  final String label;
  final bool unread;
  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      CircleAvatar(
        backgroundColor: const Color(0xffeaf1ff),
        foregroundColor: _MessengerHomeState._primary,
        child: Text(
          label.isEmpty ? '?' : label.characters.first.toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      if (unread)
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: _MessengerHomeState._primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
    ],
  );
}

class _MessengerEmpty extends StatelessWidget {
  const _MessengerEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: const Color(0xffeaf1ff),
            foregroundColor: _MessengerHomeState._primary,
            child: Icon(icon, size: 28),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xff687386)),
          ),
        ],
      ),
    ),
  );
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.onTap,
    this.destructive = false,
  });
  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool destructive;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: destructive ? Colors.red : null),
    title: Text(
      title,
      style: TextStyle(color: destructive ? Colors.red : null),
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

String _compactTime(DateTime time) {
  final now = DateTime.now();
  if (now.difference(time).inDays == 0) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
  if (now.difference(time).inDays < 7) {
    return ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][time.weekday - 1];
  }
  return '${time.day}/${time.month}';
}
