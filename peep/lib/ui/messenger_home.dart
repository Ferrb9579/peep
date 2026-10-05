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
    this.displayTime,
  });

  final String contactUsername;
  final String lastText;
  final DateTime updatedAt;
  final int unreadCount;
  final String? displayTime;
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
  final Future<String?> Function() onCreateGroup;
  final Future<void> Function() onRefreshGroups;
  final VoidCallback onSignOut;
  final List<String> logs;

  @override
  State<MessengerHome> createState() => _MessengerHomeState();
}

class _MessengerHomeState extends State<MessengerHome> {
  static const _primary = Color(0xff4f46e5);
  static const _ink = Color(0xff172033);
  static const _muted = Color(0xff667085);
  static const _border = Color(0xffe4e7ec);
  final _searchController = TextEditingController();
  int _tabIndex = 0;
  String _searchQuery = '';
  bool _unreadOnly = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
      builder: (context) => _NewGroupDialog(
        groupNameController: widget.groupNameController,
        groupMembersController: widget.groupMembersController,
        onCreate: widget.onCreateGroup,
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

  bool _matchesSearch(String title, String subtitle) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return title.toLowerCase().contains(query) ||
        subtitle.toLowerCase().contains(query);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  Widget _inbox() {
    final sourceEntries = widget.chatEntries;
    final sourceGroups = widget.groups;
    final entries = sourceEntries
        .where(
          (entry) =>
              (!_unreadOnly || entry.unreadCount > 0) &&
              _matchesSearch(entry.contactUsername, entry.lastText),
        )
        .toList(growable: false);
    final groups = _unreadOnly
        ? const <GroupSummary>[]
        : sourceGroups
              .where(
                (group) => _matchesSearch(
                  group.name,
                  '${group.members.length} members encrypted group',
                ),
              )
              .toList(growable: false);
    final empty = entries.isEmpty && groups.isEmpty;
    final hasSourceContent =
        sourceEntries.isNotEmpty || sourceGroups.isNotEmpty;

    return RefreshIndicator(
      onRefresh: widget.onRefreshGroups,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 104),
        children: [
          if (widget.connecting)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search or start a conversation',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: _clearSearch,
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: const Color(0xfff6f4ff),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 15,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _primary, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _FilterPill(
                label: 'All',
                selected: !_unreadOnly,
                onTap: () => setState(() => _unreadOnly = false),
              ),
              const SizedBox(width: 8),
              _FilterPill(
                label: 'Unread',
                selected: _unreadOnly,
                onTap: () => setState(() => _unreadOnly = true),
              ),
              const Spacer(),
              const Icon(Icons.lock_outline_rounded, size: 15, color: _muted),
              const SizedBox(width: 5),
              const Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    'End-to-end encrypted',
                    maxLines: 1,
                    style: TextStyle(color: _muted, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (empty)
            Padding(
              padding: const EdgeInsets.only(top: 58),
              child: _MessengerEmpty(
                icon: hasSourceContent
                    ? Icons.search_off_rounded
                    : Icons.markunread_outlined,
                title: hasSourceContent
                    ? 'No conversations found'
                    : 'No messages yet',
                message: hasSourceContent
                    ? 'Try another search or switch back to all conversations.'
                    : 'Start a new message to begin a private conversation.',
                actionLabel: hasSourceContent ? null : 'Start a conversation',
                onAction: hasSourceContent ? null : _showNewChat,
              ),
            ),
          for (var index = 0; index < entries.length; index++) ...[
            _ConversationTile.direct(
              entry: entries[index],
              enabled: !widget.connecting,
              onTap: () => widget.onOpenChatEntry(entries[index]),
            ),
            if (index < entries.length - 1 || groups.isNotEmpty)
              const Divider(height: 1),
          ],
          for (var index = 0; index < groups.length; index++) ...[
            _ConversationTile.group(
              group: groups[index],
              enabled: !widget.groupsBusy,
              onTap: () => widget.onOpenGroup(groups[index]),
            ),
            if (index < groups.length - 1) const Divider(height: 1),
          ],
          if (widget.groupsBusy && sourceGroups.isEmpty)
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

  void _showSettingsInfo(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => _MessengerDialog(
        title: title,
        actionLabel: 'Done',
        onAction: () => Navigator.of(context).pop(),
        child: Text(message),
      ),
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
      _SettingsTile(
        icon: Icons.person_outline,
        title: 'Account',
        onTap: () => _showSettingsInfo(
          'Account',
          '@${widget.session.username}\n${widget.session.email}',
        ),
      ),
      _SettingsTile(
        icon: Icons.lock_outline,
        title: 'Privacy',
        onTap: () => _showSettingsInfo(
          'Privacy',
          'Messages, attachments, and group conversations are end-to-end encrypted.',
        ),
      ),
      _SettingsTile(
        icon: Icons.palette_outlined,
        title: 'Appearance',
        onTap: () => _showSettingsInfo(
          'Appearance',
          'Peep currently follows its accessible light theme.',
        ),
      ),
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
      color: Colors.white,
      child: Column(
        children: [
          Container(
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: Colors.white,
            child: Row(
              children: [
                Text(
                  titles[_tabIndex],
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
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
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: body),
                if (_tabIndex == 0)
                  Positioned(
                    right: 20,
                    bottom: 18,
                    child: FloatingActionButton(
                      tooltip: 'New message',
                      onPressed: widget.connecting ? null : _showNewChat,
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                      elevation: 3,
                      child: const Icon(Icons.edit_rounded),
                    ),
                  ),
              ],
            ),
          ),
          NavigationBarTheme(
            data: NavigationBarThemeData(
              iconTheme: WidgetStateProperty.resolveWith(
                (states) => IconThemeData(
                  color: states.contains(WidgetState.selected)
                      ? _primary
                      : const Color(0xff45434d),
                  size: 24,
                ),
              ),
              labelTextStyle: WidgetStateProperty.resolveWith(
                (states) => TextStyle(
                  color: states.contains(WidgetState.selected)
                      ? _primary
                      : const Color(0xff45434d),
                  fontSize: 12,
                  fontWeight: states.contains(WidgetState.selected)
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
            ),
            child: NavigationBar(
              height: 78,
              backgroundColor: const Color(0xfff8f6ff),
              indicatorColor: const Color(0xffe8e5ff),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              selectedIndex: _tabIndex,
              onDestinationSelected: (index) =>
                  setState(() => _tabIndex = index),
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
          ),
        ],
      ),
    );
  }
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({
    required this.groupNameController,
    required this.groupMembersController,
    required this.onCreate,
  });

  final TextEditingController groupNameController;
  final TextEditingController groupMembersController;
  final Future<String?> Function() onCreate;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  bool _creating = false;
  String? _error;

  Future<void> _create() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    final error = await widget.onCreate();
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _creating = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New group'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.groupNameController,
          autofocus: true,
          enabled: !_creating,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: widget.groupMembersController,
          minLines: 2,
          maxLines: 3,
          enabled: !_creating,
          decoration: const InputDecoration(
            labelText: 'Member usernames',
            hintText: 'alex, maya, sam',
            helperText: 'Separate usernames with commas',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: _creating ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _creating ? null : _create,
        child: Text(_creating ? 'Creating…' : 'Create'),
      ),
    ],
  );
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

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? _MessengerHomeState._primary : Colors.white,
    shape: StadiumBorder(
      side: BorderSide(
        color: selected
            ? _MessengerHomeState._primary
            : _MessengerHomeState._border,
      ),
    ),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 64, minHeight: 40),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : _MessengerHomeState._ink,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
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
      color: Colors.white,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              _Avatar(label: title, group: !direct),
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
                        color: _MessengerHomeState._ink,
                        fontSize: 15,
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
                        color: _MessengerHomeState._muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 52,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      direct
                          ? entry!.displayTime ?? _compactTime(entry!.updatedAt)
                          : '',
                      style: const TextStyle(
                        color: _MessengerHomeState._muted,
                        fontSize: 11,
                      ),
                    ),
                    if (unread > 0) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: _MessengerHomeState._primary,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$unread',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
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
  const _Avatar({required this.label, this.group = false});

  final String label;
  final bool group;

  (Color, Color) get _palette {
    if (group) {
      return (const Color(0xfffff3d6), const Color(0xffdc9b00));
    }
    final normalized = label.toLowerCase();
    if (normalized.startsWith('m')) {
      return (const Color(0xffede9fe), const Color(0xff6d4ce8));
    }
    if (normalized.startsWith('a')) {
      return (const Color(0xffe8f1ff), const Color(0xff3174e8));
    }
    if (normalized.startsWith('s')) {
      return (const Color(0xffe1f7ee), const Color(0xff14a66d));
    }
    final first = label.isEmpty ? 0 : normalized.codeUnitAt(0);
    return switch (first % 4) {
      0 => (const Color(0xffede9fe), const Color(0xff6d4ce8)),
      1 => (const Color(0xffe8f1ff), const Color(0xff3174e8)),
      2 => (const Color(0xffe1f7ee), const Color(0xff14a66d)),
      _ => (const Color(0xfffff3d6), const Color(0xffdc9b00)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _palette;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: background,
          foregroundColor: foreground,
          child: group
              ? const Icon(Icons.groups_rounded, size: 25)
              : Text(
                  label.isEmpty ? '?' : label.characters.first.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ],
    );
  }
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
            style: const TextStyle(color: _MessengerHomeState._muted),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: Text(actionLabel!),
            ),
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
