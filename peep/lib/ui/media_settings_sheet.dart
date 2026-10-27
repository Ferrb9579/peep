import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../media/media_settings.dart';
import 'peep_theme.dart';

Future<void> showMediaSettings(
  BuildContext context, {
  required MediaSettings settings,
  required Future<MediaCodecSupport> Function() loadCodecs,
  required Future<String?> Function(MediaSettings) onSave,
  bool inCall = false,
  bool screenOnly = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (_) => MediaSettingsSheet(
    settings: settings,
    loadCodecs: loadCodecs,
    onSave: onSave,
    inCall: inCall,
    screenOnly: screenOnly,
  ),
);

class MediaSettingsSheet extends StatefulWidget {
  const MediaSettingsSheet({
    super.key,
    required this.settings,
    required this.loadCodecs,
    required this.onSave,
    this.inCall = false,
    this.screenOnly = false,
  });
  final MediaSettings settings;
  final Future<MediaCodecSupport> Function() loadCodecs;
  final Future<String?> Function(MediaSettings) onSave;
  final bool inCall;
  final bool screenOnly;
  @override
  State<MediaSettingsSheet> createState() => _MediaSettingsSheetState();
}

class _MediaSettingsSheetState extends State<MediaSettingsSheet> {
  final _formKey = GlobalKey<FormState>();
  late MediaSettings _settings;
  MediaCodecSupport _codecs = const MediaCodecSupport();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _loadCodecs();
  }

  Future<void> _loadCodecs() async {
    try {
      final codecs = await widget.loadCodecs();
      if (mounted) {
        setState(() {
          _codecs = codecs;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'Codec discovery is unavailable. Automatic negotiation is still available.';
        });
      }
    }
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final error = await widget.onSave(_settings);
      if (!mounted) return;
      if (error == null) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _saving = false;
          _error = error;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save your preferences. Please try again.';
        });
      }
    }
  }

  Widget _heading(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 16),
    child: Row(
      children: [
        Icon(icon, size: 20, color: PeepColors.primary),
        const SizedBox(width: 10),
        Flexible(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
      ],
    ),
  );
  Widget _codec(
    String label,
    String value,
    List<String> codecs,
    ValueChanged<String> onChanged,
  ) {
    final options = {'auto', ...codecs, if (value != 'auto') value};
    return DropdownButtonFormField<String>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: options
          .map(
            (codec) => DropdownMenuItem(
              value: codec,
              child: Text(
                codec == 'auto'
                    ? 'Automatic (recommended)'
                    : '${codec.split('/').last.toUpperCase()}${codecs.contains(codec) ? '' : ' · unavailable here'}',
              ),
            ),
          )
          .toList(),
      onChanged: _loading || _saving
          ? null
          : (value) {
              if (value != null) onChanged(value);
            },
    );
  }

  Widget _number(
    String title,
    int value,
    int min,
    int max,
    String unit,
    ValueChanged<int> onChanged,
  ) => _NumberControl(
    key: ValueKey(title),
    label: title,
    value: value,
    min: min,
    max: max,
    unit: unit,
    enabled: !_saving,
    onChanged: onChanged,
  );
  Widget _bitrate(
    String title,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
  ) => _number(title, value, min, max, 'kbps', onChanged);
  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    child: FractionallySizedBox(
      heightFactor: .9,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.screenOnly
                        ? 'Screen sharing'
                        : 'Call & media quality',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close media settings',
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.inCall
                        ? 'Bitrate and frame-rate limits apply now. Screen resolution changes apply live in browsers; on other devices, share again to change capture size. Camera capture and codecs update when media starts again.'
                        : 'Choose how you sound and look. These preferences apply to direct and group calls on this device.',
                    style: const TextStyle(
                      color: PeepColors.muted,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (!widget.screenOnly) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in MediaPreset.values)
                          ActionChip(
                            label: Text(switch (preset) {
                              MediaPreset.dataSaver => 'Data saver',
                              MediaPreset.balanced => 'Balanced',
                              MediaPreset.highQuality => 'High quality',
                            }),
                            onPressed: _saving
                                ? null
                                : () => setState(
                                    () => _settings = MediaSettings.preset(
                                      preset,
                                    ),
                                  ),
                          ),
                      ],
                    ),
                    _heading('Video', Icons.videocam_outlined),
                    _codec(
                      'Preferred video codec',
                      _settings.videoCodec,
                      _codecs.video,
                      (v) => setState(
                        () => _settings = _settings.copyWith(videoCodec: v),
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<VideoQuality>(
                      isExpanded: true,
                      initialValue: _settings.videoQuality,
                      key: ValueKey(_settings.videoQuality),
                      decoration: const InputDecoration(
                        labelText: 'Resolution',
                      ),
                      items: VideoQuality.values
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text(v.label),
                            ),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (v) => setState(
                              () => _settings = _settings.copyWith(
                                videoQuality: v,
                              ),
                            ),
                    ),
                    const SizedBox(height: 22),
                    _number(
                      'Camera frame rate',
                      _settings.frameRate,
                      1,
                      60,
                      'fps',
                      (v) => setState(
                        () => _settings = _settings.copyWith(frameRate: v),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _bitrate(
                      'Video bitrate ceiling',
                      _settings.videoBitrateKbps,
                      250,
                      8000,
                      (v) => setState(
                        () =>
                            _settings = _settings.copyWith(videoBitrateKbps: v),
                      ),
                    ),
                  ],
                  _heading('Screen sharing', Icons.screen_share_outlined),
                  const Text(
                    'Separate from your camera. Use 1 fps for slides or static text, and higher rates for scrolling or motion.',
                    style: TextStyle(
                      color: PeepColors.muted,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ScreenQuality>(
                    isExpanded: true,
                    initialValue: _settings.screenQuality,
                    key: ValueKey(_settings.screenQuality),
                    decoration: const InputDecoration(
                      labelText: 'Screen resolution',
                    ),
                    items: ScreenQuality.values
                        .map(
                          (v) =>
                              DropdownMenuItem(value: v, child: Text(v.label)),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (v) => setState(
                            () => _settings = _settings.copyWith(
                              screenQuality: v,
                            ),
                          ),
                  ),
                  const SizedBox(height: 22),
                  _number(
                    'Screen frame rate',
                    _settings.screenFrameRate,
                    1,
                    60,
                    'fps',
                    (v) => setState(
                      () => _settings = _settings.copyWith(screenFrameRate: v),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _bitrate(
                    'Screen bitrate ceiling',
                    _settings.screenBitrateKbps,
                    100,
                    20000,
                    (v) => setState(
                      () =>
                          _settings = _settings.copyWith(screenBitrateKbps: v),
                    ),
                  ),
                  if (!widget.screenOnly) ...[
                    _heading('Audio', Icons.graphic_eq_rounded),
                    _codec(
                      'Preferred audio codec',
                      _settings.audioCodec,
                      _codecs.audio,
                      (v) => setState(
                        () => _settings = _settings.copyWith(audioCodec: v),
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: _settings.sampleRate,
                      key: ValueKey(_settings.sampleRate),
                      decoration: const InputDecoration(
                        labelText: 'Audio capture quality',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 16000,
                          child: Text('Voice · 16 kHz'),
                        ),
                        DropdownMenuItem(
                          value: 48000,
                          child: Text('Full bandwidth · 48 kHz'),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (v) => setState(
                              () =>
                                  _settings = _settings.copyWith(sampleRate: v),
                            ),
                    ),
                    const SizedBox(height: 22),
                    _bitrate(
                      'Audio bitrate ceiling',
                      _settings.audioBitrateKbps,
                      24,
                      256,
                      (v) => setState(
                        () =>
                            _settings = _settings.copyWith(audioBitrateKbps: v),
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Request stereo audio'),
                      subtitle: const Text(
                        'When supported by the microphone and codec',
                      ),
                      value: _settings.stereo,
                      onChanged: _saving
                          ? null
                          : (v) => setState(
                              () => _settings = _settings.copyWith(stereo: v),
                            ),
                    ),
                    _heading('Microphone processing', Icons.mic_none_rounded),
                    for (final item in [
                      (
                        label: 'Echo cancellation',
                        value: _settings.echoCancellation,
                        change: (bool v) =>
                            _settings.copyWith(echoCancellation: v),
                      ),
                      (
                        label: 'Noise suppression',
                        value: _settings.noiseSuppression,
                        change: (bool v) =>
                            _settings.copyWith(noiseSuppression: v),
                      ),
                      (
                        label: 'Automatic gain control',
                        value: _settings.autoGainControl,
                        change: (bool v) =>
                            _settings.copyWith(autoGainControl: v),
                      ),
                    ])
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          item.label,
                          style: const TextStyle(fontSize: 14),
                        ),
                        value: item.value,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _settings = item.change(v)),
                      ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Codec preferences keep compatible fallbacks. Actual quality depends on both devices, the group server, and available bandwidth. Capture and processing requests depend on device support.',
                    style: TextStyle(
                      fontSize: 12,
                      color: PeepColors.muted,
                      height: 1.5,
                    ),
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: LinearProgressIndicator(),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: const TextStyle(color: PeepColors.danger),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              14,
              24,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving || _loading ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save preferences'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Numeric entry and a one-unit slider share a value without replacing the field
/// during typing. Invalid drafts stay visible and prevent saving.
class _NumberControl extends StatefulWidget {
  const _NumberControl({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.enabled,
    required this.onChanged,
  });
  final String label;
  final int value, min, max;
  final String unit;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  State<_NumberControl> createState() => _NumberControlState();
}

class _NumberControlState extends State<_NumberControl> {
  late final TextEditingController _controller;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(_NumberControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        int.tryParse(_controller.text) != widget.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && int.tryParse(_controller.text) != widget.value) {
          _controller.text = '${widget.value}';
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        controller: _controller,
        enabled: widget.enabled,
        decoration: InputDecoration(
          labelText: widget.label,
          suffixText: widget.unit,
          helperText:
              '${widget.min}–${widget.max} ${widget.unit} · enter an exact value',
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: (text) {
          final value = int.tryParse(text ?? '');
          return value == null || value < widget.min || value > widget.max
              ? 'Enter ${widget.min}–${widget.max} ${widget.unit}.'
              : null;
        },
        onChanged: (text) {
          final value = int.tryParse(text);
          if (value != null && value >= widget.min && value <= widget.max) {
            widget.onChanged(value);
          }
        },
      ),
      Slider(
        value: widget.value.toDouble(),
        min: widget.min.toDouble(),
        max: widget.max.toDouble(),
        divisions: widget.max - widget.min,
        label: '${widget.value} ${widget.unit}',
        semanticFormatterCallback: (value) => '${value.round()} ${widget.unit}',
        onChanged: widget.enabled
            ? (value) {
                _controller.text = '${value.round()}';
                widget.onChanged(value.round());
              }
            : null,
      ),
    ],
  );
}
