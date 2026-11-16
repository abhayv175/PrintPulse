import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// SoundService handles audible notification chimes when new paid orders arrive.
/// Synthesizes a clean 16-bit PCM WAV chime in memory with zero external asset dependencies,
/// playing crisp notification audio via AudioPlayer and system alerts.
class SoundService {
  static AudioPlayer? _audioPlayer;
  static Uint8List? _cachedChimeWav;
  static bool enabled = true;

  /// Generates a two-tone "Ding-Dong" chime (659.25 Hz [E5] -> 880 Hz [A5]) as a 16-bit mono PCM WAV.
  static Uint8List generateChimeWav({
    int sampleRate = 22050,
    double tone1Freq = 659.25,
    double tone2Freq = 880.0,
    double tone1Duration = 0.16,
    double tone2Duration = 0.28,
  }) {
    final int tone1Samples = (sampleRate * tone1Duration).toInt();
    final int tone2Samples = (sampleRate * tone2Duration).toInt();
    final int totalSamples = tone1Samples + tone2Samples;
    final int dataSize = totalSamples * 2; // 16-bit = 2 bytes per sample

    final ByteData byteData = ByteData(44 + dataSize);

    // RIFF chunk descriptor
    byteData.setUint8(0, 0x52); // 'R'
    byteData.setUint8(1, 0x49); // 'I'
    byteData.setUint8(2, 0x46); // 'F'
    byteData.setUint8(3, 0x46); // 'F'
    byteData.setUint32(4, 36 + dataSize, Endian.little);
    byteData.setUint8(8, 0x57); // 'W'
    byteData.setUint8(9, 0x41); // 'A'
    byteData.setUint8(10, 0x56); // 'V'
    byteData.setUint8(11, 0x45); // 'E'

    // "fmt " sub-chunk
    byteData.setUint8(12, 0x66); // 'f'
    byteData.setUint8(13, 0x6D); // 'm'
    byteData.setUint8(14, 0x74); // 't'
    byteData.setUint8(15, 0x20); // ' '
    byteData.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    byteData.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
    byteData.setUint16(22, 1, Endian.little); // NumChannels (1 mono)
    byteData.setUint32(24, sampleRate, Endian.little); // SampleRate
    byteData.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
    byteData.setUint16(32, 2, Endian.little); // BlockAlign (16-bit mono)
    byteData.setUint16(34, 16, Endian.little); // BitsPerSample

    // "data" sub-chunk
    byteData.setUint8(36, 0x64); // 'd'
    byteData.setUint8(37, 0x61); // 'a'
    byteData.setUint8(38, 0x74); // 't'
    byteData.setUint8(39, 0x61); // 'a'
    byteData.setUint32(40, dataSize, Endian.little);

    int offset = 44;

    // Tone 1: E5 with exponential decay
    for (int i = 0; i < tone1Samples; i++) {
      final double t = i / sampleRate;
      final double envelope = math.exp(-6.0 * (t / tone1Duration));
      final double sample = math.sin(2 * math.pi * tone1Freq * t) * envelope;
      final int intSample = (sample * 24000).clamp(-32768, 32767).toInt();
      byteData.setInt16(offset, intSample, Endian.little);
      offset += 2;
    }

    // Tone 2: A5 with exponential decay
    for (int i = 0; i < tone2Samples; i++) {
      final double t = i / sampleRate;
      final double envelope = math.exp(-4.5 * (t / tone2Duration));
      final double sample = math.sin(2 * math.pi * tone2Freq * t) * envelope;
      final int intSample = (sample * 26000).clamp(-32768, 32767).toInt();
      byteData.setInt16(offset, intSample, Endian.little);
      offset += 2;
    }

    return byteData.buffer.asUint8List();
  }

  /// Plays incoming order chime with AudioPlayer, haptic feedback, and system alert.
  static Future<void> playOrderChime() async {
    // 1. Immediate tactile and system alert feedback
    try {
      HapticFeedback.mediumImpact().catchError((_) {});
      SystemSound.play(SystemSoundType.alert).catchError((_) {});
    } catch (_) {}

    if (!enabled) return;

    // 2. High-fidelity audio chime playback via AudioPlayer (audioplayers ^6.1.0)
    try {
      _audioPlayer ??= AudioPlayer();
      await _audioPlayer!.stop();
      try {
        await _audioPlayer!.play(AssetSource('sounds/new_job.mp3'));
      } catch (_) {
        _cachedChimeWav ??= generateChimeWav();
        await _audioPlayer!.play(BytesSource(_cachedChimeWav!));
      }
    } catch (e) {
      debugPrint('SoundService audio playback fallback: $e');
    }
  }

  static void dispose() {
    try {
      _audioPlayer?.dispose();
      _audioPlayer = null;
    } catch (_) {}
  }
}
