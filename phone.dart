// Awaaz (TTS), sunna (STT) aur Android call control (MethodChannel -> MainActivity.kt).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

bool get isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class Voice {
  final FlutterTts _tts = FlutterTts();
  final SpeechToText _stt = SpeechToText();
  bool _sttReady = false;
  bool _ttsReady = false;
  void Function(String? text)? _done;
  String _last = '';

  Future<void> init() async {
    try {
      await _tts.awaitSpeakCompletion(true).timeout(const Duration(seconds: 5));
      _ttsReady = true;
    } catch (e) {
      debugPrint('TTS init error $e');
    }
    try {
      _sttReady = await _stt
          .initialize(
            onError: (e) => _finish(null),
            onStatus: (s) {
              if (s == 'done' || s == 'notListening') {
                Future.delayed(
                  const Duration(milliseconds: 400),
                  () => _finish(_last.isEmpty ? null : _last),
                );
              }
            },
          )
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (e) {
      debugPrint('STT init error $e');
      _sttReady = false;
    }
  }

  /// Bolta hai aur bolna khatam hone tak wait karta hai.
  /// TTS kabhi atak jaye toh bot na ruke: max time ke baad aage badho.
  Future<void> speak(
    String text, {
    String lang = 'en-IN',
    double pitch = 0.7,
    double rate = 0.45,
  }) async {
    debugPrint('[BOT] $text');
    if (!_ttsReady) return;
    Future<void> run() async {
      await _tts.setLanguage(lang);
      await _tts.setPitch(pitch); // 0.7 = male awaaz
      await _tts.setSpeechRate(rate);
      await _tts.speak(text);
    }

    try {
      await run().timeout(Duration(milliseconds: 4000 + text.length * 120));
    } catch (e) {
      debugPrint('TTS error/timeout $e');
    }
  }

  /// Bolna/sunna band. Kabhi atke nahi isliye har call pe time-limit.
  Future<void> stop() async {
    _finish(null);
    try {
      await _tts.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      if (_stt.isListening) await _stt.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  bool get canListen => _sttReady;

  void _finish(String? v) {
    final d = _done;
    _done = null;
    if (d != null) d(v);
  }

  /// Ek jawab suno. null = kuch samajh nahi aaya / mic nahi hai.
  Future<String?> listen({String localeId = 'en_IN'}) async {
    if (!_sttReady) return null;
    final c = Completer<String?>();
    _last = '';
    _done = (v) {
      if (!c.isCompleted) c.complete(v);
    };
    try {
      await _stt.listen(
        onResult: (SpeechRecognitionResult r) {
          _last = r.recognizedWords;
          if (r.finalResult) _finish(_last.isEmpty ? null : _last);
        },
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 3),
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (e) {
      debugPrint('STT listen error $e');
      _finish(null);
    }
    return c.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => _last.isEmpty ? null : _last,
    );
  }
}

/// Android native (MainActivity.kt) se baat karne wala channel.
class Phone {
  static const _ch = MethodChannel('ira/phone');

  static Future<T?> _call<T>(String method, [dynamic args]) async {
    if (!isAndroid) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('phone.$method error $e');
      return null;
    }
  }

  /// CallReceiver.kt jo likhta hai: {state: RINGING/OFFHOOK/IDLE, number, ts}
  static Future<Map<String, dynamic>?> callState() async {
    final m = await _call<Map>('callState');
    return m == null ? null : Map<String, dynamic>.from(m);
  }

  static Future<bool> answer() async =>
      (await _call<bool>('answer')) ?? !isAndroid;
  static Future<bool> end() async => (await _call<bool>('end')) ?? !isAndroid;
  static Future<void> speaker(bool on) => _call('speaker', on);
  static Future<void> toBack() => _call('toBack');
}
