import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../i18n/phrases.dart';

/// Speaks the app's instructions, so it can be used without reading.
class SpeechService {
  final FlutterTts _tts = FlutterTts();

  String _languageCode = 'en';
  bool _configured = false;

  String get languageCode => _languageCode;

  Set<String> _available = {};

  /// Which of our languages this device actually has a voice for.
  ///
  /// iOS ships no voice for several Indic languages, and asking it to speak
  /// one it lacks fails silently — so the UI has to be able to say so rather
  /// than leave someone tapping a button that does nothing.
  Future<Set<String>> refreshAvailable() async {
    try {
      final raw = await _tts.getLanguages as List?;
      final locales = (raw ?? []).map((e) => '$e'.toLowerCase()).toList();
      debugPrint('TTS voices on this device: $locales');

      _available = supportedLanguages
          .where((l) => locales.any((loc) =>
              loc == l.ttsLocale.toLowerCase() ||
              loc.startsWith('${l.code}-') ||
              loc == l.code))
          .map((l) => l.code)
          .toSet();
      debugPrint('TTS usable for: $_available');
    } catch (e) {
      debugPrint('TTS getLanguages failed: $e');
    }
    return _available;
  }

  /// Whether this language can be spoken at all, directly or via a stand-in.
  bool canSpeak(String code) {
    if (_available.isEmpty) return true; // not probed yet — let it try
    if (_available.contains(code)) return true;
    final via = languageByCode(code).spokenVia;
    return via != null && _available.contains(via);
  }

  /// The language whose voice and wording will actually be used.
  String get _spokenCode {
    if (_available.isEmpty || _available.contains(_languageCode)) {
      return _languageCode;
    }
    final via = languageByCode(_languageCode).spokenVia;
    return (via != null && _available.contains(via)) ? via : _languageCode;
  }

  Future<void> setLanguage(String code) async {
    _languageCode = code;
    _configured = false;
    await _configure();
  }

  Future<void> _configure() async {
    if (_configured) return;
    final language = languageByCode(_spokenCode);
    try {
      await _tts.setLanguage(language.ttsLocale);
      // Slower than default: instructions land better when unhurried, and
      // these are spoken to someone who cannot fall back on reading them.
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1);
      _configured = true;
    } catch (e) {
      debugPrint('TTS configure failed: $e');
    }
  }

  Future<void> say(Phrase phrase) async {
    if (!canSpeak(_languageCode)) return;
    await _configure();
    try {
      await _tts.stop();
      await _tts.speak(phraseText(_spokenCode, phrase));
    } catch (e) {
      debugPrint('TTS speak failed: $e');
    }
  }

  /// Reads arbitrary text, for the language picker's own sample.
  Future<void> sayRaw(String text) async {
    await _configure();
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing was speaking.
    }
  }
}
