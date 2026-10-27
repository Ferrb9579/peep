import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/peer.dart';
import 'package:peep/ui/account_screen.dart';
import 'package:peep/ui/call_screen.dart';
import 'package:peep/ui/conversation_screen.dart';
import 'package:peep/ui/media_settings_sheet.dart';
import 'package:peep/ui/messenger_home.dart';
import 'package:peep/ui/peep_theme.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _accountHarness({
  required List<TextEditingController> fields,
  required VoidCallback onCreate,
  required VoidCallback onSignIn,
  bool busy = false,
  double textScale = 1,
}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
  child: MaterialApp(
    theme: buildPeepTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: AccountScreen(
          signalingController: fields[0],
          emailController: fields[1],
          usernameController: fields[2],
          passwordController: fields[3],
          busy: busy,
          onCreateAccount: onCreate,
          onSignIn: onSignIn,
        ),
      ),
    ),
  ),
);

List<TextEditingController> _accountFields() => [
  TextEditingController(text: 'ws://localhost:8787/ws'),
  TextEditingController(),
  TextEditingController(),
  TextEditingController(),
];

void _disposeFields(Iterable<TextEditingController> fields) {
  for (final field in fields) {
    field.dispose();
  }
}

Widget _homeHarness({
  required TextEditingController signaling,
  required TextEditingController contact,
  required TextEditingController groupName,
  required TextEditingController groupMembers,
  bool connecting = false,
  bool groupsBusy = false,
  Future<String?> Function()? onCreateGroup,
  VoidCallback? onConnect,
  double textScale = 1,
}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
  child: MaterialApp(
    theme: buildPeepTheme(),
    home: Scaffold(
      body: MessengerHome(
        signalingController: signaling,
        contactController: contact,
        groupNameController: groupName,
        groupMembersController: groupMembers,
        session: const AuthSession(
          token: 'token',
          username: 'auditor',
          email: 'auditor@example.com',
        ),
        chatEntries: const [],
        groups: const [],
        callHistory: const [],
        connecting: connecting,
        groupsBusy: groupsBusy,
        onConnect: onConnect ?? () {},
        onOpenChatEntry: (_) {},
        onCreateGroup: onCreateGroup ?? () async => null,
        onOpenGroup: (_) {},
        onRefreshGroups: () async {},
        onSignOut: () {},
        logs: const ['socket connected', 'mailbox loaded'],
        onMediaSettings: () {},
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connection settings cancel rolls back and save validates', (
    tester,
  ) async {
    _useViewport(tester, const Size(1280, 900));
    final fields = _accountFields();
    addTearDown(() => _disposeFields(fields));
    await tester.pumpWidget(
      _homeHarness(
        signaling: fields[0],
        contact: fields[1],
        groupName: fields[2],
        groupMembers: fields[3],
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connection settings'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'https://wrong.test');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fields[0].text, 'ws://localhost:8787/ws');

    await tester.tap(find.text('Connection settings'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'https://wrong.test');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a ws:// or wss:// server address.'),
      findsOneWidget,
    );
    expect(fields[0].text, 'ws://localhost:8787/ws');
    await tester.enterText(
      find.byType(TextFormField),
      '  wss://relay.test/ws  ',
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(fields[0].text, 'wss://relay.test/ws');
  });

  testWidgets(
    'account creation rejects malformed inputs then accepts valid inputs',
    (tester) async {
      _useViewport(tester, const Size(320, 568));
      final fields = _accountFields();
      addTearDown(() => _disposeFields(fields));
      var created = 0;
      var signedIn = 0;
      await tester.pumpWidget(
        _accountHarness(
          fields: fields,
          onCreate: () => created++,
          onSignIn: () => signedIn++,
          textScale: 1.25,
        ),
      );

      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'not-an-email');
      await tester.enterText(find.byType(TextFormField).at(1), 'tw');
      await tester.enterText(find.byType(TextFormField).at(2), 'short');
      await tester.ensureVisible(find.text('Create my account'));
      await tester.tap(find.text('Create my account'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(
        find.text('Use 3–32 letters, numbers, underscores or hyphens.'),
        findsOneWidget,
      );
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(created, 0);

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'alice@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'alice_123');
      await tester.enterText(find.byType(TextFormField).at(2), 'correct horse');
      await tester.ensureVisible(find.text('Create my account'));
      await tester.tap(find.text('Create my account'));
      await tester.pump();
      expect(created, 1);
      expect(signedIn, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account sign-in stays disabled while busy and validates expanded server URL',
    (tester) async {
      _useViewport(tester, const Size(390, 844));
      final fields = _accountFields();
      addTearDown(() => _disposeFields(fields));
      var submissions = 0;
      await tester.pumpWidget(
        _accountHarness(
          fields: fields,
          onCreate: () => submissions++,
          onSignIn: () => submissions++,
        ),
      );
      await tester.enterText(find.byType(TextFormField).at(0), 'alice');
      await tester.enterText(find.byType(TextFormField).at(1), 'password');
      await tester.tap(find.text('Connection settings'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(2), 'https://wrong');
      await tester.ensureVisible(find.text('Sign in securely'));
      await tester.tap(find.text('Sign in securely'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a ws:// or wss:// server address.'),
        findsOneWidget,
      );
      expect(submissions, 0);

      await tester.pumpWidget(
        _accountHarness(
          fields: fields,
          onCreate: () => submissions++,
          onSignIn: () => submissions++,
          busy: true,
        ),
      );
      expect(find.text('Sign in securely'), findsNothing);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(submissions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'media codec picker keeps unsupported preference visible and saves fallback',
    (tester) async {
      _useViewport(tester, const Size(390, 844));
      MediaSettings? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeepTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showMediaSettings(
                    context,
                    settings: MediaSettings.defaults.copyWith(
                      videoCodec: 'video/hevc',
                    ),
                    loadCodecs: () async => const MediaCodecSupport(
                      video: ['video/vp8'],
                      audio: ['audio/opus'],
                    ),
                    onSave: (settings) async {
                      saved = settings;
                      return null;
                    },
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(find.text('HEVC · unavailable here'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('Preferred video codec:video/hevc')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('VP8'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('Preferred audio codec:auto')),
      );
      await tester.tap(
        find.byKey(const ValueKey('Preferred audio codec:auto')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OPUS'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save preferences'));
      await tester.tap(find.text('Save preferences'));
      await tester.pumpAndSettle();

      expect(saved?.videoCodec, 'video/vp8');
      expect(saved?.audioCodec, 'audio/opus');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('codec discovery and storage failures remain recoverable', (
    tester,
  ) async {
    _useViewport(tester, const Size(390, 844));
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showMediaSettings(
                  context,
                  settings: MediaSettings.defaults,
                  loadCodecs: () async => throw StateError('codec API failed'),
                  onSave: (_) async {
                    attempts++;
                    if (attempts == 1) throw StateError('storage unavailable');
                    return null;
                  },
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Codec discovery is unavailable. Automatic negotiation is still available.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('Preferred video codec:auto')),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Save preferences'));
    await tester.tap(find.text('Save preferences'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save your preferences. Please try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Save preferences'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Call & media quality'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('media preference store round-trips across store instances', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final settings = MediaSettings(
      videoCodec: 'video/h264',
      audioCodec: 'audio/opus',
      videoQuality: VideoQuality.fullHd,
      frameRate: 50,
      videoBitrateKbps: 6200,
      audioBitrateKbps: 144,
      sampleRate: 16000,
      stereo: true,
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
    );

    await MediaSettingsStore().save(settings);
    final restored = await MediaSettingsStore().load();
    expect(restored.toJson(), settings.toJson());
  });

  testWidgets(
    'media settings remain scrollable on a small screen with large text',
    (tester) async {
      _useViewport(tester, const Size(320, 568));
      MediaSettings? saved;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.7)),
          child: MaterialApp(
            theme: buildPeepTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showMediaSettings(
                      context,
                      settings: MediaSettings.defaults,
                      loadCodecs: () async => const MediaCodecSupport(),
                      onSave: (settings) async {
                        saved = settings;
                        return null;
                      },
                    ),
                    child: const Text('Open settings'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(find.text('Call & media quality'), findsOneWidget);
      final scrollable = find.byType(Scrollable).last;
      for (final label in [
        'Request stereo audio',
        'Echo cancellation',
        'Noise suppression',
        'Automatic gain control',
      ]) {
        await tester.scrollUntilVisible(
          find.text(label),
          120,
          scrollable: scrollable,
        );
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      await tester.scrollUntilVisible(
        find.text('Save preferences'),
        120,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Save preferences'));
      await tester.pumpAndSettle();
      expect(saved?.stereo, isTrue);
      expect(saved?.echoCancellation, isFalse);
      expect(saved?.noiseSuppression, isFalse);
      expect(saved?.autoGainControl, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline conversation disables call but keeps reconnect and settings actions',
    (tester) async {
      var calls = 0;
      var reconnects = 0;
      var settings = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeepTheme(),
          home: Scaffold(
            body: ConversationHeader(
              room: 'Maya',
              peer: '',
              statusLabel: 'Disconnected',
              statusColor: Colors.red,
              encryptionReady: false,
              canReconnect: true,
              canCall: false,
              onBack: () {},
              onReconnect: () => reconnects++,
              onStartCall: () => calls++,
              onMediaSettings: () => settings++,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Connect to start a call'));
      await tester.tap(find.byTooltip('Reconnect chat'));
      await tester.tap(find.byTooltip('Call & media quality'));
      expect(calls, 0);
      expect(reconnects, 1);
      expect(settings, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline direct composer queues by button and keyboard; locked composer does not send',
    (tester) async {
      final input = TextEditingController();
      final scroll = ScrollController();
      addTearDown(input.dispose);
      addTearDown(scroll.dispose);
      var queued = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeepTheme(),
          home: Scaffold(
            body: ConversationPanel(
              messages: const [],
              scrollController: scroll,
              messageController: input,
              canType: true,
              canSend: false,
              canAttach: false,
              onSend: () => queued++,
              onAttach: () {},
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Queue this for later');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      expect(queued, 1);
      expect(find.byTooltip('Queue until connected'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'Queue this from the button',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Queue until connected'));
      expect(queued, 2);
      await tester.tap(find.byTooltip('Attach audio or video'));
      expect(queued, 2);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeepTheme(),
          home: Scaffold(
            body: ConversationPanel(
              messages: const [],
              scrollController: scroll,
              messageController: input,
              canType: false,
              canSend: false,
              canAttach: false,
              onSend: () => queued++,
              onAttach: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Queue until connected'));
      expect(queued, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('incoming and outgoing call actions work at narrow width', (
    tester,
  ) async {
    _useViewport(tester, const Size(320, 568));
    var accepts = 0;
    var declines = 0;
    var cancels = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: MaterialApp(
          theme: buildPeepTheme(),
          home: CallScreen(
            title: 'A very long caller display name',
            subtitle: 'Direct message',
            callState: CallState.incoming,
            connected: false,
            cameraEnabled: false,
            microphoneEnabled: true,
            screenShareEnabled: false,
            localVideoViewType: null,
            remoteVideoViews: const [],
            onAccept: () => accepts++,
            onDecline: () => declines++,
            onEnd: () {},
            onToggleCamera: () {},
            onToggleMicrophone: () {},
            onToggleScreenShare: () {},
            onMediaSettings: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Accept'));
    await tester.tap(find.byTooltip('Decline'));
    expect(accepts, 1);
    expect(declines, 1);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: CallScreen(
          title: 'Maya',
          subtitle: 'Direct message',
          callState: CallState.outgoing,
          connected: false,
          cameraEnabled: false,
          microphoneEnabled: true,
          screenShareEnabled: false,
          localVideoViewType: null,
          remoteVideoViews: const [],
          onAccept: () {},
          onDecline: () {},
          onEnd: () => cancels++,
          onToggleCamera: () {},
          onToggleMicrophone: () {},
          onToggleScreenShare: () {},
          onMediaSettings: () {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Cancel'));
    expect(cancels, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'active call controls invoke microphone camera screen share and end',
    (tester) async {
      _useViewport(tester, const Size(390, 844));
      var muted = 0;
      var camera = 0;
      var share = 0;
      var ended = 0;
      var media = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeepTheme(),
          home: CallScreen(
            title: 'Maya',
            subtitle: 'Connected',
            callState: CallState.active,
            connected: true,
            cameraEnabled: false,
            microphoneEnabled: true,
            screenShareEnabled: false,
            localVideoViewType: null,
            remoteVideoViews: const [MediaView(title: 'Maya', viewType: null)],
            onAccept: () {},
            onDecline: () {},
            onEnd: () => ended++,
            onToggleCamera: () => camera++,
            onToggleMicrophone: () => muted++,
            onToggleScreenShare: () => share++,
            onMediaSettings: () => media++,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Mute'));
      await tester.tap(find.byTooltip('Camera on'));
      await tester.tap(find.byTooltip('Share screen'));
      await tester.tap(find.byTooltip('End call'));
      await tester.tap(find.byTooltip('Call & media quality'));
      expect(muted, 1);
      expect(camera, 1);
      expect(share, 1);
      expect(ended, 1);
      expect(media, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new group catches thrown backend errors and permits retry', (
    tester,
  ) async {
    _useViewport(tester, const Size(320, 568));
    final signaling = TextEditingController(text: 'ws://localhost:8787/ws');
    final contact = TextEditingController();
    final name = TextEditingController();
    final members = TextEditingController();
    addTearDown(() => _disposeFields([signaling, contact, name, members]));
    var attempts = 0;
    await tester.pumpWidget(
      _homeHarness(
        signaling: signaling,
        contact: contact,
        groupName: name,
        groupMembers: members,
        onCreateGroup: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return null;
        },
        textScale: 1.25,
      ),
    );
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not create the group. Please try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('New group'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('valid new-message form invokes connect once and rejects self', (
    tester,
  ) async {
    _useViewport(tester, const Size(390, 844));
    final signaling = TextEditingController(text: 'ws://localhost:8787/ws');
    final contact = TextEditingController();
    final name = TextEditingController();
    final members = TextEditingController();
    addTearDown(() => _disposeFields([signaling, contact, name, members]));
    var connections = 0;
    await tester.pumpWidget(
      _homeHarness(
        signaling: signaling,
        contact: contact,
        groupName: name,
        groupMembers: members,
        onConnect: () => connections++,
      ),
    );

    await tester.tap(find.text('Start a conversation'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'AUDITOR');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Choose someone other than yourself.'), findsOneWidget);
    expect(connections, 0);

    await tester.enterText(find.byType(TextFormField), '  MaYa  ');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('New message'), findsNothing);
    expect(connections, 1);
    expect(contact.text, '  MaYa  ');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'busy inbox blocks starting a direct conversation and scales through tabs',
    (tester) async {
      _useViewport(tester, const Size(390, 844));
      final signaling = TextEditingController(text: 'ws://localhost:8787/ws');
      final contact = TextEditingController();
      final name = TextEditingController();
      final members = TextEditingController();
      addTearDown(() => _disposeFields([signaling, contact, name, members]));
      var connections = 0;
      await tester.pumpWidget(
        _homeHarness(
          signaling: signaling,
          contact: contact,
          groupName: name,
          groupMembers: members,
          connecting: true,
          onConnect: () => connections++,
          textScale: 1,
        ),
      );
      await tester.tap(find.text('Start a conversation'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.tap(find.text('Connecting…'));
      expect(connections, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Calls').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('No calls yet'), findsOneWidget);
      await tester.tap(find.text('Settings').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.scrollUntilVisible(
        find.text('Connection activity'),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Connection activity'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('socket connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
