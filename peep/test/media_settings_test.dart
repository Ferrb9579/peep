import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:peep/media/media_settings.dart';
import 'package:peep/media/webrtc_media_native.dart';
import 'package:peep/models/conversation_id.dart';

class _Track extends Fake implements MediaStreamTrack {
  _Track(this.kind);
  @override
  final String kind;
}

class _Sender extends Fake implements RTCRtpSender {
  _Sender(String kind, this.parameters, {this.accept = true})
    : track = _Track(kind);
  @override
  MediaStreamTrack? track;
  List<MediaStream>? streams;
  @override
  Future<void> replaceTrack(MediaStreamTrack? value) async {
    track = value;
  }

  @override
  Future<void> setStreams(List<MediaStream> value) async {
    streams = value;
  }

  @override
  final RTCRtpParameters parameters;
  final bool accept;
  RTCRtpParameters? applied;
  @override
  Future<bool> setParameters(RTCRtpParameters parameters) async {
    applied = parameters;
    return accept;
  }
}

class _Connection extends Fake implements RTCPeerConnection {
  _Connection(this._senders, [this.mediaTransceivers = const []]);
  final List<RTCRtpTransceiver> mediaTransceivers;
  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => mediaTransceivers;
  final List<RTCRtpSender> _senders;
  @override
  Future<List<RTCRtpSender>> getSenders() async => _senders;
}

class _Receiver extends Fake implements RTCRtpReceiver {
  _Receiver(this.track);
  @override
  final MediaStreamTrack track;
}

class _Transceiver extends Fake implements RTCRtpTransceiver {
  _Transceiver(this.sender, String kind) : receiver = _Receiver(_Track(kind));
  @override
  final RTCRtpSender sender;
  @override
  final RTCRtpReceiver receiver;
  TransceiverDirection? direction;
  @override
  Future<void> setDirection(TransceiverDirection value) async {
    direction = value;
  }
}

class _Stream extends Fake implements MediaStream {}

void main() {
  test('corrupted persisted values cannot request unsafe sender limits', () {
    final settings = MediaSettings.fromJson({
      'videoQuality': 'unknown',
      'frameRate': 500,
      'videoBitrateKbps': -1,
      'audioBitrateKbps': 0,
      'sampleRate': 1,
      'stereo': 'true',
    });
    expect(settings.frameRate, 60);
    expect(settings.videoBitrateKbps, 250);
    expect(settings.audioBitrateKbps, 24);
    expect(settings.sampleRate, 48000);
    expect(settings.stereo, false);
    expect(settings.videoQuality, VideoQuality.hd);
    final restored = MediaSettings.fromJson(
      MediaSettings.preset(MediaPreset.highQuality).toJson(),
    );
    expect(
      restored.toJson(),
      MediaSettings.preset(MediaPreset.highQuality).toJson(),
    );
  });
  test(
    'camera and screen preserve independent one-fps settings and repair old preferences',
    () {
      final settings = MediaSettings.fromJson(
        const MediaSettings(
          frameRate: 1,
          screenFrameRate: 1,
          screenBitrateKbps: 777,
          screenQuality: ScreenQuality.original,
        ).toJson(),
      );
      expect(settings.frameRate, 1);
      expect(settings.screenFrameRate, 1);
      expect(settings.screenBitrateKbps, 777);
      expect(settings.screenConstraints.containsKey('width'), false);
      expect(settings.screenConstraints['frameRate'], {'ideal': 1, 'max': 1});
      expect(nativeScreenConstraints(settings), {'frameRate': 1});
      final old = MediaSettings.fromJson({'frameRate': 7});
      expect(old.frameRate, 7);
      expect(old.screenFrameRate, 15);
      expect(old.screenQuality, ScreenQuality.fullHd);
      final repaired = MediaSettings.fromJson({
        'screenFrameRate': 0,
        'screenBitrateKbps': 99999,
        'screenQuality': 'invalid',
      });
      expect(repaired.screenFrameRate, 1);
      expect(repaired.screenBitrateKbps, 20000);
      expect(repaired.screenQuality, ScreenQuality.fullHd);
    },
  );

  test(
    'screen sender limits pause only video and restore camera limits',
    () async {
      final video = _Sender(
        'video',
        RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 42)]),
      );
      final audio = _Sender(
        'audio',
        RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 43)]),
      );
      final connection = _Connection([video, audio]);
      const settings = MediaSettings(
        frameRate: 7,
        videoBitrateKbps: 901,
        screenFrameRate: 1,
        screenBitrateKbps: 777,
        audioBitrateKbps: 55,
      );
      await applyNativeSenderLimits(
        connection,
        settings,
        screenSharing: true,
        screenPaused: true,
      );
      final encoding = video.applied!.encodings!.single;
      expect(encoding.maxFramerate, 1);
      expect(encoding.maxBitrate, 777000);
      expect(encoding.active, false);
      expect(audio.applied!.encodings!.single.active, true);
      expect(audio.applied!.encodings!.single.maxBitrate, 55000);
      await applyNativeSenderLimits(connection, settings, screenSharing: true);
      expect(encoding.active, true);
      expect(encoding.maxFramerate, 1);
      await applyNativeSenderLimits(connection, settings);
      expect(encoding.active, true);
      expect(encoding.maxFramerate, 7);
      expect(encoding.maxBitrate, 901000);
      expect(encoding.ssrc, 42);
    },
  );

  test('codec preference preserves peer fallbacks and repair codecs', () {
    final codecs = [
      'video/VP8',
      'video/rtx',
      'video/H264',
      'video/H264',
      'video/red',
    ];
    expect(prioritizeCodecs(codecs, 'video/h264', (mime) => mime), [
      'video/H264',
      'video/H264',
      'video/VP8',
      'video/rtx',
      'video/red',
    ]);
    expect(prioritizeCodecs(codecs, 'video/AV1', (mime) => mime), codecs);
    expect(prioritizeCodecs(codecs, 'auto', (mime) => mime), codecs);
  });
  test(
    'live sender limits preserve negotiated transaction, codec and SSRC',
    () async {
      final encoding = RTCRtpEncoding(ssrc: 42, rid: 'main', maxBitrate: 9999);
      final parameters = RTCRtpParameters(
        transactionId: 'negotiated',
        encodings: [encoding],
        codecs: [RTCRTPCodec(name: 'H264', payloadType: 102)],
      );
      final video = _Sender('video', parameters);
      final audio = _Sender(
        'audio',
        RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 43)]),
      );
      await applyNativeSenderLimits(
        _Connection([video, audio]),
        const MediaSettings(
          videoBitrateKbps: 2400,
          audioBitrateKbps: 96,
          frameRate: 24,
        ),
      );
      expect(video.applied!.transactionId, 'negotiated');
      expect(video.applied!.codecs!.single.payloadType, 102);
      expect(encoding.ssrc, 42);
      expect(encoding.rid, 'main');
      expect(encoding.maxBitrate, 2400000);
      expect(encoding.maxFramerate, 24);
      expect(audio.applied!.encodings!.single.maxBitrate, 96000);
      expect(audio.applied!.encodings!.single.maxFramerate, isNull);
    },
  );
  test(
    'device rejection is reported instead of claiming a successful update',
    () async {
      final sender = _Sender(
        'video',
        RTCRtpParameters(encodings: [RTCRtpEncoding()]),
        accept: false,
      );
      expect(
        applyNativeSenderLimits(_Connection([sender]), MediaSettings.defaults),
        throwsStateError,
      );
    },
  );
  test(
    'screen source replacement reuses the negotiated video sender',
    () async {
      final video = _Sender(
        'video',
        RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 42)]),
      );
      final audio = _Sender(
        'audio',
        RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 43)]),
      );
      final transceiver = _Transceiver(video, 'video');
      final connection = _Connection(
        [audio, video],
        [_Transceiver(audio, 'audio'), transceiver],
      );
      final stream = _Stream();
      final screen = _Track('video');
      await detachNativeVideoSenders(connection);
      expect(video.track, isNull);
      expect(audio.track!.kind, 'audio');
      expect(transceiver.direction, TransceiverDirection.RecvOnly);
      await attachNativeMediaTrack(connection, stream, screen);
      expect(video.track, same(screen));
      expect(video.streams!.single, same(stream));
      expect(transceiver.direction, TransceiverDirection.SendRecv);
      expect(video.parameters.encodings!.single.ssrc, 42);
      final replacement = _Track('video');
      await attachNativeMediaTrack(connection, stream, replacement);
      expect(video.track, same(replacement));
      expect(connection.mediaTransceivers.length, 2);
    },
  );
  test('direct conversation keys are stable across role and casing', () {
    expect(
      directConversationId(' Alice ', 'BOB'),
      directConversationId('bob', 'alice'),
    );
    expect(directConversationId(' Alice ', 'BOB'), 'dm:alice:bob');
  });
}
