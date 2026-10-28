import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/models/conversation_drafts.dart';
import 'package:peep/peer.dart';
import 'package:peep/ui/call_screen.dart';
import 'package:peep/ui/conversation_screen.dart';
import 'package:peep/ui/interaction_feedback.dart';
import 'package:peep/ui/media_settings_sheet.dart';
import 'package:peep/ui/peep_theme.dart';

Widget _app(Widget child, {bool reducedMotion = false}) => MaterialApp(
  theme: buildPeepTheme().copyWith(platform: TargetPlatform.linux),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: Scaffold(body: child),
    ),
  ),
);

void main() {
  test(
    'drafts isolate conversations, retain selection, and clear on sign-out',
    () {
      final drafts = ConversationDrafts();
      final input = TextEditingController();
      addTearDown(input.dispose);
      drafts.open('direct:alice:bob', input);
      input.value = const TextEditingValue(
        text: 'Ask Bob',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      drafts.open(null, input);
      expect(input.text, isEmpty);
      drafts.open('group:crew', input);
      expect(input.text, isEmpty);
      input.text = 'Group plan';
      drafts.open('direct:alice:bob', input);
      expect(input.text, 'Ask Bob');
      expect(input.selection.baseOffset, 3);
      expect(input.value.composing, TextRange.empty);
      input.text = 'Reconnecting';
      drafts.open('direct:alice:bob', input);
      expect(input.text, 'Reconnecting');
      drafts.open('group:crew', input);
      expect(input.text, 'Group plan');
      drafts.clear(input);
      drafts.open('direct:alice:bob', input);
      expect(input.text, isEmpty);
      drafts.open('group:crew', input);
      expect(input.text, isEmpty);
    },
  );
  test('sent drafts do not reappear after leaving', () {
    final drafts = ConversationDrafts();
    final input = TextEditingController();
    addTearDown(input.dispose);
    drafts.open('direct:a:b', input);
    input.text = 'Draft';
    drafts.open(null, input);
    drafts.open('direct:a:b', input);
    input.clear();
    drafts.open(null, input);
    drafts.open('direct:a:b', input);
    expect(input.text, isEmpty);
  });
  late TextEditingController input;
  late ScrollController scroll;
  setUp(() {
    input = TextEditingController();
    scroll = ScrollController();
  });
  tearDown(() {
    input.dispose();
    scroll.dispose();
  });
  Widget panel({
    List<ChatMessage> messages = const [],
    VoidCallback? onSend,
    bool canType = true,
  }) => _app(
    ConversationPanel(
      messages: messages,
      messageController: input,
      scrollController: scroll,
      canType: canType,
      canSend: true,
      canAttach: false,
      onSend: onSend ?? () {},
      onAttach: () {},
    ),
  );
  testWidgets('Enter sends once, Shift+Enter adds a line, and focus stays', (
    tester,
  ) async {
    var sends = 0;
    await tester.pumpWidget(
      panel(
        onSend: () {
          sends++;
          input.clear();
        },
      ),
    );
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(input.text, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      true,
    );
    await tester.enterText(find.byType(TextField), 'Line one');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sends, 1);
    expect(input.text, 'Line one\n');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sends, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 2);
  });
  testWidgets('IME composition and disabled composer cannot send', (
    tester,
  ) async {
    var sends = 0;
    await tester.pumpWidget(panel(onSend: () => sends++));
    await tester.tap(find.byType(TextField));
    input.value = const TextEditingValue(
      text: ' composing',
      selection: TextSelection.collapsed(offset: 10),
      composing: TextRange(start: 1, end: 10),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    expect(sends, 0);
    await tester.pumpWidget(panel(canType: false, onSend: () => sends++));
    input.text = 'Cannot send';
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    expect(sends, 0);
  });
  testWidgets('remote arrivals preserve scroll; latest button catches up', (
    tester,
  ) async {
    final messages = List.generate(
      35,
      (i) => ChatMessage(
        text: 'Message $i',
        isLocal: false,
        sentAt: DateTime(2026, 10, 27, 12, i),
      ),
    );
    await tester.pumpWidget(panel(messages: messages));
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Jump to latest'), findsOneWidget);
    final before = scroll.offset;
    messages.add(
      ChatMessage(text: 'New arrival', isLocal: false, sentAt: DateTime.now()),
    );
    await tester.pumpWidget(panel(messages: messages));
    await tester.pumpAndSettle();
    expect(scroll.offset, before);
    expect(find.text('1 new message'), findsOneWidget);
    await tester.tap(find.text('1 new message'));
    await tester.pumpAndSettle();
    expect(scroll.position.extentAfter, lessThan(2));
    expect(find.text('New arrival'), findsOneWidget);
    messages.add(
      ChatMessage(text: 'My reply', isLocal: true, sentAt: DateTime.now()),
    );
    await tester.pumpWidget(panel(messages: messages));
    await tester.pumpAndSettle();
    expect(scroll.position.extentAfter, lessThan(2));
    expect(tester.takeException(), null);
  });
  testWidgets(
    'search opens from keyboard, filters case-insensitively, clears and closes',
    (tester) async {
      final messages = [
        ChatMessage(
          text: 'Coffee tomorrow?',
          isLocal: false,
          sentAt: DateTime.now(),
        ),
        ChatMessage(
          text: 'Saturday walk',
          isLocal: true,
          sentAt: DateTime.now(),
        ),
      ];
      await tester.pumpWidget(panel(messages: messages));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final search = find.widgetWithText(TextField, 'Search this conversation');
      await tester.enterText(search, 'COFFEE');
      await tester.pumpAndSettle();
      expect(find.text('1 message found'), findsOneWidget);
      expect(find.text('Coffee tomorrow?'), findsOneWidget);
      expect(find.text('Saturday walk'), findsNothing);
      await tester.enterText(search, 'not found');
      await tester.pumpAndSettle();
      expect(find.text('No matching messages'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear message search'));
      await tester.pumpAndSettle();
      expect(find.text('2 messages'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      expect(find.text('Saturday walk'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  testWidgets('copy confirms success and quote preserves the existing draft', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      panel(
        messages: [
          ChatMessage(
            text: 'Bring coffee\nand cake',
            isLocal: false,
            sentAt: DateTime.now(),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy message'));
    await tester.pumpAndSettle();
    expect(copied, 'Bring coffee\nand cake');
    expect(find.text('Copied to clipboard'), findsOneWidget);
    input.text = 'My draft';
    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quote in reply'));
    await tester.pumpAndSettle();
    expect(input.text, '> Bring coffee\n> and cake\n\nMy draft');
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      true,
    );
  });
  testWidgets(
    'screen-only defaults fix invalid input and preserve audio/camera',
    (tester) async {
      MediaSettings? saved;
      final original = MediaSettings.preset(
        MediaPreset.highQuality,
      ).copyWith(screenFrameRate: 1);
      await tester.pumpWidget(
        _app(
          MediaSettingsSheet(
            settings: original,
            screenOnly: true,
            loadCodecs: () async => const MediaCodecSupport(),
            onSave: (value) async {
              saved = value;
              return 'Keep open to inspect';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Screen frame rate'),
        '0',
      );
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.ensureVisible(find.text('Restore defaults'));
      await tester.tap(find.text('Restore defaults'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save preferences'));
      await tester.pumpAndSettle();
      expect(saved!.screenFrameRate, MediaSettings.defaults.screenFrameRate);
      expect(saved!.screenQuality, MediaSettings.defaults.screenQuality);
      expect(
        saved!.screenBitrateKbps,
        MediaSettings.defaults.screenBitrateKbps,
      );
      expect(saved!.videoQuality, original.videoQuality);
      expect(saved!.audioBitrateKbps, original.audioBitrateKbps);
      expect(saved!.stereo, original.stereo);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'call shortcuts toggle media and focus without leaking through modals',
    (tester) async {
      var mic = true;
      var camera = false;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, update) => CallScreen(
              title: 'Maya',
              subtitle: '',
              callState: CallState.active,
              connected: true,
              microphoneEnabled: mic,
              cameraEnabled: camera,
              screenShareEnabled: false,
              localVideoViewType: null,
              remoteVideoViews: const [
                MediaView(title: 'Maya', viewType: 'test-video'),
              ],
              onAccept: () {},
              onDecline: () {},
              onEnd: () {},
              onToggleMicrophone: () => update(() => mic = !mic),
              onToggleCamera: () => update(() => camera = !camera),
              onToggleScreenShare: () {},
              onMediaSettings: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(mic, false);
      expect(find.text('Your microphone is off'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(camera, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Exit full screen'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Call shortcuts'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(mic, false);
      expect(tester.takeException(), null);
    },
  );
  testWidgets('reduced motion disables custom press animation', (tester) async {
    await tester.pumpWidget(
      _app(const PeepPress(child: Text('Press')), reducedMotion: true),
    );
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
      Duration.zero,
    );
    expect(tester.takeException(), null);
  });
}
