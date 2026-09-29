import 'package:flutter/services.dart';

/// The platform's own speech engine, used on Android.
///
/// The command line engines this app drives elsewhere (`piper`, `espeak-ng`
/// plus an audio player) simply do not exist on a phone, which is why speech was
/// silent there. Android always ships a [TextToSpeech] engine, so the platform
/// channel is the only way to speak on that OS.
class SystemTts {
  const SystemTts();

  static const _channel = MethodChannel('com.example.review_app/tts');

  /// The name of the engine, or null when this device has no voice data.
  Future<String?> engineName() async {
    try {
      return await _channel.invokeMethod<String>('engineName');
    } on Object {
      return null;
    }
  }

  /// Speaks [text] and completes when the utterance finishes. Returns false if
  /// the line could not be spoken.
  Future<bool> speak(String text) async {
    try {
      return await _channel.invokeMethod<bool>('speak', {'text': text}) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Stops the current utterance and abandons anything pending.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // Nothing to stop.
    }
  }

  /// The English voices installed on the device, best quality first.
  Future<List<TtsVoice>> voices() async {
    try {
      final voices = await _channel.invokeMethod<List<Object?>>('voices');
      if (voices == null) return const [];
      return [
        for (final voice in voices)
          if (voice is Map)
            TtsVoice(
              name: voice['name'] as String? ?? '',
              locale: voice['locale'] as String? ?? '',
              quality: voice['quality'] as String? ?? '',
              score: (voice['score'] as num?)?.toInt() ?? 0,
              requiresNetwork: voice['network'] as bool? ?? false,
              isAvailable: voice['available'] as bool? ?? true,
              isSelected: voice['selected'] as bool? ?? false,
            ),
      ]..sort((a, b) {
        if (a.isSelected != b.isSelected) return a.isSelected ? -1 : 1;
        if (a.requiresNetwork != b.requiresNetwork) {
          return a.requiresNetwork ? 1 : -1;
        }
        if (a.score != b.score) return b.score.compareTo(a.score);
        return a.name.compareTo(b.name);
      });
    } on Object {
      return const [];
    }
  }

  /// The speed and pitch the engine is using now, so a slider can open where
  /// the last choice left it rather than snapping back to the default.
  Future<SpeechSettings> settings() async {
    try {
      final values = await _channel.invokeMapMethod<String, Object?>(
        'settings',
      );
      if (values == null) return const SpeechSettings();
      return SpeechSettings(
        rate: (values['rate'] as num?)?.toDouble() ?? 1,
        pitch: (values['pitch'] as num?)?.toDouble() ?? 1,
      );
    } on Object {
      return const SpeechSettings();
    }
  }

  /// Switches to the voice called [name]. Returns false if it is not installed,
  /// in which case the platform default keeps speaking.
  Future<bool> selectVoice(String name) async {
    try {
      return await _channel.invokeMethod<bool>('setVoice', {'name': name}) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Sets the speaking speed, where 1.0 is the platform default.
  Future<bool> setRate(double rate) async {
    try {
      return await _channel.invokeMethod<bool>('setRate', {'rate': rate}) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Sets the pitch, where 1.0 is the platform default.
  Future<bool> setPitch(double pitch) async {
    try {
      return await _channel.invokeMethod<bool>('setPitch', {'pitch': pitch}) ??
          false;
    } on Object {
      return false;
    }
  }
}

/// How fast and how high the engine is speaking, where 1.0 is the default.
class SpeechSettings {
  const SpeechSettings({this.rate = 1, this.pitch = 1});

  final double rate;
  final double pitch;
}

/// One installed voice, as the platform reports it.
class TtsVoice {
  const TtsVoice({
    required this.name,
    required this.locale,
    required this.quality,
    this.score = 0,
    required this.requiresNetwork,
    required this.isAvailable,
    required this.isSelected,
  });

  /// The engine's own name for the voice, e.g. `en-us-x-sfg#female_1-local`.
  final String name;

  final String locale;

  /// `High`, `Enhanced`, `Normal` or `Low`, as the engine grades its voices.
  final String quality;

  /// The number behind [quality], which is what the picker sorts on: the
  /// engine's own grade, where a bigger number is a better voice.
  final int score;

  /// A voice that streams its audio needs a connection to speak.
  final bool requiresNetwork;

  /// Whether the voice's data is actually installed on the device.
  final bool isAvailable;

  final bool isSelected;

  /// A name short enough for a list tile, without the engine's own noise.
  String get shortName {
    final name = this.name.split('#').last;
    return name.replaceAll(RegExp('[-_]'), ' ').trim();
  }
}
