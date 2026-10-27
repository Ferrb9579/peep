// Headed browser entrypoint for manual UI and WebRTC QA.
// Synthetic devices are installed before the production app initializes, so
// this fixture never requests access to a physical camera or microphone.
// ignore_for_file: avoid_relative_lib_imports, avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../lib/main.dart' as app;

bool _deniedCaptureConsumed = false;
int _screenCaptures = 0;

Future<void> main() async {
  _installSyntheticMedia();
  _showQaBanner();
  await app.main();
}

void _installSyntheticMedia() {
  final devices = html.window.navigator.mediaDevices;
  if (devices == null) {
    throw StateError('This browser does not expose navigator.mediaDevices.');
  }

  final mediaDevices = JSObject.fromInteropObject(devices);
  mediaDevices['getUserMedia'] = ((JSAny? constraints) => _captureForBrowser(
    constraints,
  )).toJS;
  mediaDevices['getDisplayMedia'] = ((JSAny? constraints) => _captureForBrowser(
    constraints,
    screen: true,
  )).toJS;
}

JSAny? _captureForBrowser(JSAny? constraints, {bool screen = false}) {
  if (screen) {
    _screenCaptures++;
  }
  final mode = Uri.parse(html.window.location.href).queryParameters['media'];
  final videoRequested = _isRequested((constraints as JSObject?)?['video']);
  if (mode == 'denied' && !_deniedCaptureConsumed) {
    _deniedCaptureConsumed = true;
    return _rejected(
      _domException(
        'NotAllowedError',
        'Synthetic media permission was denied by ?media=denied.',
      ),
    );
  }
  if (mode == 'missing' || mode == 'missing-video' && videoRequested) {
    return _rejected(
      _domException(
        'NotFoundError',
        'Synthetic media devices are unavailable by ?media=$mode.',
      ),
    );
  }
  return _capture(constraints, screen: screen).toJS;
}

Future<JSObject> _capture(JSAny? rawConstraints, {bool screen = false}) async {
  final constraints = rawConstraints as JSObject?;
  final audioRequested = _isRequested(constraints?['audio']);
  final videoRequest = constraints?['video'];
  final videoRequested = _isRequested(videoRequest);
  if (!audioRequested && !videoRequested) {
    throw _domException(
      'TypeError',
      'Synthetic capture requires audio or video to be enabled.',
    );
  }

  final fixture = _SyntheticCapture();
  try {
    if (videoRequested) fixture.addVideo(videoRequest, screen: screen);
    if (audioRequested) await fixture.addAudio();
    return fixture.stream;
  } catch (_) {
    fixture.dispose();
    rethrow;
  }
}

bool _isRequested(JSAny? value) {
  if (value == null) return false;
  if (value.isA<JSBoolean>()) return (value as JSBoolean).toDart;
  return true;
}

JSObject _domException(String name, String message) {
  final constructor = globalContext['DOMException'] as JSFunction?;
  if (constructor != null) {
    return constructor.callAsConstructor<JSObject>(message.toJS, name.toJS);
  }
  final error = (globalContext['Error'] as JSFunction)
      .callAsConstructor<JSObject>(message.toJS);
  error['name'] = name.toJS;
  return error;
}

JSPromise<JSAny?> _rejected(JSObject error) =>
    (globalContext['Promise'] as JSObject).callMethod<JSPromise<JSAny?>>(
      'reject'.toJS,
      error,
    );

class _SyntheticCapture {
  final JSObject stream = (globalContext['MediaStream'] as JSFunction)
      .callAsConstructor<JSObject>();
  final List<JSObject> _tracks = [];
  Timer? _frameTimer;
  JSObject? _audioContext;
  JSObject? _oscillator;
  int _remainingTracks = 0;
  bool _disposed = false;

  void addVideo(JSAny? request, {bool screen = false}) {
    final constraints = request != null && request.isA<JSObject>()
        ? request as JSObject
        : null;
    final width = _constraintNumber(
      constraints?['width'],
    ).round().clamp(1, 3840).toInt();
    final height = _constraintNumber(
      constraints?['height'],
      fallback: 360,
    ).round().clamp(1, 2160).toInt();
    final frameRate = _constraintNumber(
      constraints?['frameRate'],
      fallback: 30,
    ).round().clamp(1, 60).toInt();
    final canvas = html.CanvasElement(width: width, height: height);
    final context = canvas.context2D;
    var frame = 0;

    void paintFrame() {
      final hue = (frame * 7) % 360;
      context
        ..fillStyle = 'hsl($hue 58% 40%)'
        ..fillRect(0, 0, width, height)
        ..fillStyle = '#ffffff'
        ..font = 'bold ${max(18, width ~/ 24)}px sans-serif'
        ..fillText(
          screen
              ? 'PEEP QA · SYNTHETIC SCREEN $_screenCaptures'
              : 'PEEP QA · SYNTHETIC CAMERA',
          24,
          42,
        )
        ..font = '${max(14, width ~/ 40)}px sans-serif'
        ..fillText('frame $frame · $width×$height · $frameRate fps', 24, 76);
      frame++;
    }

    paintFrame();
    final canvasObject = JSObject.fromInteropObject(canvas);
    final captured = canvasObject.callMethod<JSObject>(
      'captureStream'.toJS,
      frameRate.toJS,
    );
    final videoTracks = captured
        .callMethod<JSArray<JSObject>>('getVideoTracks'.toJS)
        .toDart;
    for (final track in videoTracks) {
      _addTrack(track);
    }
    _frameTimer = Timer.periodic(
      Duration(milliseconds: (1000 / frameRate).round()),
      (_) => paintFrame(),
    );
  }

  Future<void> addAudio() async {
    final constructor =
        (globalContext['AudioContext'] ?? globalContext['webkitAudioContext'])
            as JSFunction?;
    if (constructor == null) {
      throw StateError('Web Audio is unavailable in this browser.');
    }
    final audio = constructor.callAsConstructor<JSObject>();
    _audioContext = audio;
    final oscillator = audio.callMethod<JSObject>('createOscillator'.toJS);
    final destination = audio.callMethod<JSObject>(
      'createMediaStreamDestination'.toJS,
    );
    _oscillator = oscillator;
    oscillator.callMethod<JSAny?>('connect'.toJS, destination);
    oscillator.callMethod<JSAny?>('start'.toJS);
    final audioStream = destination['stream'] as JSObject;
    final audioTracks = audioStream
        .callMethod<JSArray<JSObject>>('getAudioTracks'.toJS)
        .toDart;
    for (final track in audioTracks) {
      _addTrack(track);
    }
    if ((audio['state'] as JSString).toDart != 'running') {
      await audio.callMethod<JSPromise<JSAny?>>('resume'.toJS).toDart;
    }
  }

  void _addTrack(JSObject track) {
    _tracks.add(track);
    _remainingTracks++;
    stream.callMethod<JSAny?>('addTrack'.toJS, track);

    var stopped = false;
    void markStopped() {
      if (stopped) return;
      stopped = true;
      _remainingTracks--;
      if (_remainingTracks == 0) dispose();
    }

    track.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'ended'.toJS,
      markStopped.toJS,
    );
    final originalStop = track['stop'] as JSFunction;
    track['stop'] = (() {
      originalStop.callAsFunction(track);
      markStopped();
    }).toJS;
  }

  double _constraintNumber(JSAny? value, {double fallback = 640}) {
    if (value == null) return fallback;
    if (value.isA<JSNumber>()) return (value as JSNumber).toDartDouble;
    if (value.isA<JSObject>()) {
      final dictionary = value as JSObject;
      for (final key in ['exact', 'ideal', 'max', 'min']) {
        final nested = dictionary[key];
        if (nested != null && nested.isA<JSNumber>()) {
          return (nested as JSNumber).toDartDouble;
        }
      }
    }
    return fallback;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _frameTimer?.cancel();
    _frameTimer = null;
    for (final track in _tracks) {
      try {
        (track['stop'] as JSFunction).callAsFunction(track);
      } catch (_) {
        // Continue releasing the remaining tracks after one stop failure.
      }
    }
    final oscillator = _oscillator;
    _oscillator = null;
    if (oscillator != null) {
      try {
        oscillator.callMethod<JSAny?>('stop'.toJS);
      } catch (_) {
        // It may already have stopped as part of browser track teardown.
      }
    }
    final audio = _audioContext;
    _audioContext = null;
    if (audio != null && (audio['state'] as JSString).toDart != 'closed') {
      unawaited(audio.callMethod<JSPromise<JSAny?>>('close'.toJS).toDart);
    }
  }
}

void _showQaBanner() {
  final banner = html.DivElement()
    ..text = 'QA synthetic media'
    ..style.position = 'fixed'
    ..style.top = '8px'
    ..style.right = '8px'
    ..style.zIndex = '2147483647'
    ..style.padding = '5px 8px'
    ..style.borderRadius = '5px'
    ..style.backgroundColor = 'rgba(20, 24, 32, 0.82)'
    ..style.color = '#ffffff'
    ..style.font = '12px/1.2 sans-serif'
    ..style.pointerEvents = 'none';
  html.document.body?.append(banner);
}

int max(int first, int second) => first > second ? first : second;
