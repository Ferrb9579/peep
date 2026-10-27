import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peep/models/call_session.dart';
import 'package:peep/peer.dart';
import 'package:peep/ui/call_screen.dart';
import 'package:peep/ui/peep_theme.dart';

Widget callHarness({
  CallState state = CallState.active,
  List<MediaView> views = const [
    MediaView(title: 'Maya', viewType: 'test-video'),
  ],
  bool group = false,
  bool connected = true,
}) => MaterialApp(
  theme: buildPeepTheme(),
  home: CallScreen(
    title: 'Maya',
    subtitle: '',
    callState: state,
    connected: connected,
    isGroup: group,
    cameraEnabled: false,
    microphoneEnabled: true,
    screenShareEnabled: false,
    localVideoViewType: null,
    remoteVideoViews: views,
    onAccept: () {},
    onDecline: () {},
    onEnd: () {},
    onToggleCamera: () {},
    onToggleMicrophone: () {},
    onToggleScreenShare: () {},
    onMediaSettings: () {},
  ),
);

void main() {
  test('call duration excludes ringing and summary is recorded once', () {
    var now = DateTime(2026, 10, 6, 12);
    final session = CallSessionTracker(now: () => now);
    session.update(CallState.outgoing, title: 'Maya', group: false);
    now = now.add(const Duration(seconds: 20));
    session.update(CallState.active, title: 'Maya', group: false);
    now = now.add(const Duration(seconds: 65));
    session.update(CallState.idle, title: 'Maya', group: false);
    final summary = session.summary;
    expect(summary!.duration, const Duration(seconds: 65));
    expect(formatCallDuration(summary.duration), '01:05');
    session.update(CallState.idle, title: 'Maya', group: false);
    expect(identical(summary, session.summary), true);
    session.update(CallState.incoming, title: 'Alex', group: false);
    expect(session.summary, null);
    session.update(CallState.idle, title: 'Alex', group: false);
    expect(session.summary!.outcome, 'Missed call');
    expect(session.summary!.connected, false);
    expect(session.summary!.outgoing, false);
  });

  test('cancel, decline, group retry, and reset preserve correct outcomes', () {
    final session = CallSessionTracker();
    session.update(CallState.outgoing, title: 'Crew', group: true);
    session.endOutcome = 'Call canceled';
    session.update(CallState.idle, title: 'Crew', group: true);
    expect(session.summary!.outcome, 'Call canceled');
    expect(session.summary!.group, true);
    expect(session.summary!.duration, Duration.zero);
    session.update(CallState.incoming, title: 'Maya', group: false);
    session.endOutcome = 'Call declined';
    session.update(CallState.idle, title: 'Maya', group: false);
    expect(session.summary!.outcome, 'Call declined');
    session.reset();
    expect(session.summary, null);
    expect(session.connectedAt, null);
  });

  testWidgets('tap video, zoom controls, pinch, reset, and Escape', (
    tester,
  ) async {
    await tester.pumpWidget(callHarness());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tile-Maya-test-video')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Exit full screen'), findsOneWidget);
    expect(find.byTooltip('Mute'), findsNothing);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1.5);
    await tester.tap(find.text('Reset zoom'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);

    final video = find.byType(InteractiveViewer);
    await tester.tap(video);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(video);
    await tester.pump();
    expect(find.text('200%'), findsOneWidget);
    await tester.tap(find.text('Reset zoom'));
    await tester.pump();

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final left = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    await left.moveTo(center - const Offset(35, 0));
    await right.moveTo(center + const Offset(35, 0));
    await tester.pump();
    await left.moveTo(center - const Offset(80, 0));
    await right.moveTo(center + const Offset(80, 0));
    await tester.pump();
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await left.up();
    await right.up();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byTooltip('Mute'), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets('expanded video loss returns to call and grid layouts fit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(callHarness());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Full screen Maya'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      callHarness(views: const [MediaView(title: 'Maya', viewType: null)]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.byTooltip('Grid layout'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Focus layout'), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.pumpWidget(
      callHarness(
        group: true,
        views: List.generate(
          8,
          (index) => MediaView(title: 'Member $index', viewType: null),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GridView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Member 7'), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets('ringing and ended screens fit small landscape with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final state in [CallState.outgoing, CallState.incoming]) {
      await tester.pumpWidget(callHarness(state: state));
      await tester.pumpAndSettle();
      expect(
        find.text(state == CallState.incoming ? 'Incoming call' : 'Ringing…'),
        findsWidgets,
      );
      expect(tester.takeException(), null);
    }
    var retries = 0;
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeepTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: CallEndedScreen(
            summary: CallSummary(
              title: 'Maya',
              group: false,
              outgoing: true,
              startedAt: DateTime(2026),
              duration: const Duration(seconds: 65),
              connected: true,
              outcome: 'Call ended',
            ),
            onDone: () => done++,
            onCallAgain: () => retries++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Call again'));
    await tester.tap(find.text('Call again'));
    await tester.ensureVisible(find.text('Back to chat'));
    await tester.tap(find.text('Back to chat'));
    expect(retries, 1);
    expect(done, 1);
    expect(tester.takeException(), null);
  });
}
