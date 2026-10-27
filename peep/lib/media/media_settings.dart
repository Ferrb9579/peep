import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum VideoQuality {
  dataSaver('360p', 640, 360),
  standard('480p', 854, 480),
  hd('720p', 1280, 720),
  fullHd('1080p', 1920, 1080);

  const VideoQuality(this.label, this.width, this.height);
  final String label;
  final int width;
  final int height;
}

enum MediaPreset { dataSaver, balanced, highQuality }

enum ScreenQuality {
  original('Original size', null, null),
  hd('720p', 1280, 720),
  fullHd('1080p', 1920, 1080),
  quadHd('1440p', 2560, 1440),
  ultraHd('2160p · 4K', 3840, 2160);

  const ScreenQuality(this.label, this.width, this.height);
  final String label;
  final int? width;
  final int? height;
}

/// Local preferences are requests and bandwidth ceilings, not delivery guarantees.
class MediaSettings {
  const MediaSettings({
    this.videoCodec = 'auto',
    this.audioCodec = 'auto',
    this.videoQuality = VideoQuality.hd,
    this.frameRate = 30,
    this.videoBitrateKbps = 1800,
    this.screenQuality = ScreenQuality.fullHd,
    this.screenFrameRate = 15,
    this.screenBitrateKbps = 2500,
    this.audioBitrateKbps = 64,
    this.sampleRate = 48000,
    this.stereo = false,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
  });
  final String videoCodec;
  final String audioCodec;
  final VideoQuality videoQuality;
  final int frameRate;
  final int videoBitrateKbps;
  final ScreenQuality screenQuality;
  final int screenFrameRate;
  final int screenBitrateKbps;
  final int audioBitrateKbps;
  final int sampleRate;
  final bool stereo;
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;

  static const defaults = MediaSettings();
  static MediaSettings preset(MediaPreset preset) => switch (preset) {
    MediaPreset.dataSaver => const MediaSettings(
      videoQuality: VideoQuality.dataSaver,
      frameRate: 15,
      videoBitrateKbps: 400,
      screenQuality: ScreenQuality.hd,
      screenFrameRate: 5,
      screenBitrateKbps: 600,
      audioBitrateKbps: 32,
      sampleRate: 16000,
    ),
    MediaPreset.balanced => defaults,
    MediaPreset.highQuality => const MediaSettings(
      videoQuality: VideoQuality.fullHd,
      frameRate: 60,
      videoBitrateKbps: 4500,
      screenQuality: ScreenQuality.quadHd,
      screenFrameRate: 30,
      screenBitrateKbps: 6000,
      audioBitrateKbps: 128,
      stereo: true,
    ),
  };

  MediaSettings copyWith({
    String? videoCodec,
    String? audioCodec,
    VideoQuality? videoQuality,
    int? frameRate,
    int? videoBitrateKbps,
    ScreenQuality? screenQuality,
    int? screenFrameRate,
    int? screenBitrateKbps,
    int? audioBitrateKbps,
    int? sampleRate,
    bool? stereo,
    bool? echoCancellation,
    bool? noiseSuppression,
    bool? autoGainControl,
  }) => MediaSettings(
    videoCodec: videoCodec ?? this.videoCodec,
    audioCodec: audioCodec ?? this.audioCodec,
    videoQuality: videoQuality ?? this.videoQuality,
    frameRate: frameRate ?? this.frameRate,
    videoBitrateKbps: videoBitrateKbps ?? this.videoBitrateKbps,
    screenQuality: screenQuality ?? this.screenQuality,
    screenFrameRate: screenFrameRate ?? this.screenFrameRate,
    screenBitrateKbps: screenBitrateKbps ?? this.screenBitrateKbps,
    audioBitrateKbps: audioBitrateKbps ?? this.audioBitrateKbps,
    sampleRate: sampleRate ?? this.sampleRate,
    stereo: stereo ?? this.stereo,
    echoCancellation: echoCancellation ?? this.echoCancellation,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    autoGainControl: autoGainControl ?? this.autoGainControl,
  );

  Map<String, dynamic> get videoConstraints => {
    'width': {'ideal': videoQuality.width},
    'height': {'ideal': videoQuality.height},
    'frameRate': {'ideal': frameRate, 'max': frameRate},
    'facingMode': 'user',
  };
  Map<String, dynamic> get audioConstraints => {
    'sampleRate': {'ideal': sampleRate},
    'channelCount': {'ideal': stereo ? 2 : 1},
    'echoCancellation': echoCancellation,
    'noiseSuppression': noiseSuppression,
    'autoGainControl': autoGainControl,
  };
  Map<String, dynamic> get screenConstraints => {
    if (screenQuality.width != null)
      'width': {'ideal': screenQuality.width, 'max': screenQuality.width},
    if (screenQuality.height != null)
      'height': {'ideal': screenQuality.height, 'max': screenQuality.height},
    'frameRate': {'ideal': screenFrameRate, 'max': screenFrameRate},
  };

  Map<String, dynamic> toJson() => {
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'videoQuality': videoQuality.name,
    'frameRate': frameRate,
    'videoBitrateKbps': videoBitrateKbps,
    'screenQuality': screenQuality.name,
    'screenFrameRate': screenFrameRate,
    'screenBitrateKbps': screenBitrateKbps,
    'audioBitrateKbps': audioBitrateKbps,
    'sampleRate': sampleRate,
    'stereo': stereo,
    'echoCancellation': echoCancellation,
    'noiseSuppression': noiseSuppression,
    'autoGainControl': autoGainControl,
  };
  factory MediaSettings.fromJson(Map<String, dynamic> json) {
    int number(String key, int fallback, int min, int max) => json[key] is num
        ? (json[key] as num).toInt().clamp(min, max)
        : fallback;
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    return MediaSettings(
      videoCodec: json['videoCodec'] is String
          ? json['videoCodec'] as String
          : 'auto',
      audioCodec: json['audioCodec'] is String
          ? json['audioCodec'] as String
          : 'auto',
      videoQuality:
          VideoQuality.values
              .where((v) => v.name == json['videoQuality'])
              .firstOrNull ??
          VideoQuality.hd,
      frameRate: number('frameRate', 30, 1, 60),
      videoBitrateKbps: number('videoBitrateKbps', 1800, 250, 8000),
      screenQuality:
          ScreenQuality.values
              .where((v) => v.name == json['screenQuality'])
              .firstOrNull ??
          ScreenQuality.fullHd,
      screenFrameRate: number('screenFrameRate', 15, 1, 60),
      screenBitrateKbps: number('screenBitrateKbps', 2500, 100, 20000),
      audioBitrateKbps: number('audioBitrateKbps', 64, 24, 256),
      sampleRate: json['sampleRate'] == 16000 ? 16000 : 48000,
      stereo: flag('stereo', false),
      echoCancellation: flag('echoCancellation', true),
      noiseSuppression: flag('noiseSuppression', true),
      autoGainControl: flag('autoGainControl', true),
    );
  }
}

class MediaCodecSupport {
  const MediaCodecSupport({this.video = const [], this.audio = const []});
  final List<String> video;
  final List<String> audio;
}

/// Keep fallback and repair codecs to negotiate with peers using other stacks.
List<T> prioritizeCodecs<T>(
  List<T> codecs,
  String preferred,
  String Function(T) mimeType,
) {
  if (preferred == 'auto') return List<T>.of(codecs);
  bool matches(T codec) =>
      mimeType(codec).toLowerCase() == preferred.toLowerCase();
  return [
    ...codecs.where(matches),
    ...codecs.where((codec) => !matches(codec)),
  ];
}

class MediaSettingsStore {
  static const _key = 'peep:media-settings:v1';
  final _preferences = SharedPreferencesAsync();
  Future<MediaSettings> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return MediaSettings.defaults;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic>
          ? MediaSettings.fromJson(json)
          : MediaSettings.defaults;
    } on FormatException {
      return MediaSettings.defaults;
    }
  }

  Future<void> save(MediaSettings settings) =>
      _preferences.setString(_key, jsonEncode(settings.toJson()));
}
