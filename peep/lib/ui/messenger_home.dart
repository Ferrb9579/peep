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
  static const _primary = Color(0xff4f46e5);
  int _tabIndex = 0;
  int _filterIndex = 0;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectTab(int index) => setState(() => _tabIndex = index);


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
                        if (mounted) _showNewChat();
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
                        if (mounted) _showNewGroup();
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inbox() {
    final query = _searchController.text.trim().toLowerCase();
    final chats = widget.chatEntries.where((entry) =>
        _filterIndex != 2 &&
        (_filterIndex != 1 || entry.unreadCount > 0) &&
        (entry.contactUsername.toLowerCase().contains(query) ||
            entry.lastText.toLowerCase().contains(query))).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final groups = widget.groups.where((group) =>
        _filterIndex != 1 && group.name.toLowerCase().contains(query)).toList();
    final empty = widget.chatEntries.isEmpty && widget.groups.isEmpty;
    final noMatches = chats.isEmpty && groups.isEmpty;
    return RefreshIndicator(
      onRefresh: () async => widget.onRefreshGroups(),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search conversations',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: query.isEmpty ? null : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () => setState(_searchController.clear),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (index, label) in
                          ['All', 'Unread', 'Groups'].indexed)
                        ChoiceChip(
                          label: Text(label),
                          selected: _filterIndex == index,
                          onSelected: (_) => setState(() => _filterIndex = index),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  if (widget.connecting || widget.groupsBusy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                ],
              ),
            ),
          ),
          if (noMatches)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MessengerEmpty(
                icon: empty ? Icons.forum_outlined : Icons.search_off_rounded,
                title: empty ? 'Your people, one conversation away' :
                    'No conversations found',
                message: empty
                    ? 'Start a private message or bring your people together in a group.'
                    : 'Try another search or choose a different filter.',
                actionLabel: empty ? 'Start a conversation' : 'Reset filters',
                onAction: empty ? _showComposeSheet : () => setState(() {
                  _searchController.clear();
                  _filterIndex = 0;
                }),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: index < chats.length
                        ? _ConversationTile.direct(
                            entry: chats[index],
                            enabled: !widget.connecting,
                            onTap: () => widget.onOpenChatEntry(chats[index]),
                          )
                        : _ConversationTile.group(
                            group: groups[index - chats.length],
                            enabled: !widget.groupsBusy,
                            onTap: () => widget.onOpenGroup(
                                groups[index - chats.length]),
                          ),
                  ),
                  childCount: chats.length + groups.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _calls() {
    if (widget.callHistory.isEmpty) {
      return const SingleChildScrollView(
        child: _MessengerEmpty(
          icon: Icons.call_outlined,
          title: 'Room for a familiar voice',
          message: 'Open a conversation to start a call. Your recent calls will appear here.',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
    const titles = ['Chats', 'Calls', 'Settings'];
    const subtitles = [
      'A little closer to your people.',
      'Good conversations go beyond text.',
      'Make yourself at home.',
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      final content = Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(24, wide ? 32 : 20, 16, 24),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(titles[_tabIndex],
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      Text(subtitles[_tabIndex],
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                if (_tabIndex == 0) ...[
                  const SizedBox(width: 12),
                  IconButton.filled(
                    tooltip: 'Start a conversation',
                    onPressed: _showComposeSheet,
                    icon: const Icon(Icons.edit_square),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: switch (_tabIndex) {
              0 => _inbox(),
              1 => _calls(),
              _ => _settings(),
            },
          ),
          if (!wide)
            NavigationBar(
              selectedIndex: _tabIndex,
              onDestinationSelected: _selectTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline_rounded),
                  selectedIcon: Icon(Icons.chat_bubble_rounded),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.call_outlined),
                  selectedIcon: Icon(Icons.call_rounded),
                  label: 'Calls',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: 'Settings',
                ),
              ],
            ),
        ],
      );
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Row(
          children: [
            if (wide) ...[
              NavigationRail(
                selectedIndex: _tabIndex,
                onDestinationSelected: _selectTab,
                labelType: NavigationRailLabelType.all,
                groupAlignment: -0.7,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('peep',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: _primary, fontWeight: FontWeight.w900)),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.chat_bubble_outline_rounded),
                    selectedIcon: Icon(Icons.chat_bubble_rounded),
                    label: Text('Chats'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.call_outlined),
                    selectedIcon: Icon(Icons.call_rounded),
                    label: Text('Calls'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: Text('Settings'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: content,
                ),
              ),
            ),
          ],
        ),
      );
    });
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
    scrollable: true,
    content: SizedBox(width: 400, child: child),
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
      color: unread > 0 ? const Color(0xffeef2ff) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: unread > 0 ? const Color(0xffc7d2fe) : const Color(0xffe4e7ec),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              direct
                  ? _Avatar(label: title, unread: unread > 0)
                  : const CircleAvatar(
                      radius: 24,
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
              if (direct)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _compactTime(entry!.updatedAt),
                        style: TextStyle(
                          color: unread > 0 ? _MessengerHomeState._primary :
                              const Color(0xff687386),
                          fontSize: 11,
                          fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(height: 6),
                        Container(
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _MessengerHomeState._primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Semantics(
                            label: '$unread unread messages',
                            excludeSemantics: true,
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 11,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
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
        radius: 24,
        backgroundColor: const Color(0xffe0e7ff),
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
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: const Color(0xffe0e7ff),
            foregroundColor: _MessengerHomeState._primary,
            child: Icon(icon, size: 28),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xff687386)),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 24),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
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
    enabled: onTap != null,
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    onTap: onTap,
  );
}

String _compactTime(DateTime time) {
  time = time.toLocal();
  final now = DateTime.now();
  final days = DateTime.utc(now.year, now.month, now.day)
      .difference(DateTime.utc(time.year, time.month, time.day)).inDays;
  if (days == 0) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) {
    return ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][time.weekday - 1];
  }
  return '${time.day}/${time.month}';
}
