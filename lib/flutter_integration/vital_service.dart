import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'native_vital_bridge.dart';

class VitalPayload {
  final List<double> samples;
  final Uint8List imagePixels;
  final int width;
  final int height;

  VitalPayload(this.samples, this.imagePixels, this.width, this.height);
}

class VitalService {
  
  Future<void> initialize() async {
    NativeVitalBridge.init();
  }

  final List<double> _rpmHistory = [];

  Future<VitalResult> processCameraFrames(List<double> luminanceSamples, Uint8List imagePixels, int imgWidth, int imgHeight) async {
    if (luminanceSamples.isEmpty) return VitalResult(0, 0, 0, [], []);

    try {
      final payload = VitalPayload(luminanceSamples, imagePixels, imgWidth, imgHeight);
      final VitalResult result = await compute(_calculateInBackground, payload);
      
      // Iniezione dello Sleep Staging Mock se stiamo usando Dart Fallback
      int sleepState = -1;
      double sleepConfidence = 0.0;

      if (result.rpm > 0) {
        _rpmHistory.add(result.rpm);
        if (_rpmHistory.length > 30) _rpmHistory.removeAt(0);

        if (_rpmHistory.length >= 10) {
          double sum = 0;
          for (double r in _rpmHistory) sum += r;
          double avg = sum / _rpmHistory.length;

          double varSum = 0;
          for (double r in _rpmHistory) varSum += (r - avg) * (r - avg);
          double variance = varSum / _rpmHistory.length;

          if (variance > 4.0) {
            sleepState = 3; // REM
            sleepConfidence = 0.85;
          } else if (avg > 18.0) {
            sleepState = 0; // WAKE
            sleepConfidence = 0.90;
          } else if (avg < 14.5 && variance < 1.0) {
            sleepState = 2; // DEEP
            sleepConfidence = 0.95;
          } else {
            sleepState = 1; // LIGHT
            sleepConfidence = 0.70;
          }
        }
      }

      return VitalResult(
        result.bpm, 
        result.rpm, 
        result.confidence, 
        result.respWave, 
        result.cardioWave,
        sleepState: sleepState,
        sleepConfidence: sleepConfidence,
        postureState: result.postureState,
        sidsRiskFlag: result.sidsRiskFlag,
      );
    } catch (e) {
      debugPrint("ERRORE CRITICO NATIVO FFI: $e");
      return VitalResult(0, 0, 0, [], []);
    }
  }

  static VitalResult _calculateInBackground(VitalPayload payload) {
    // Prova a usare il bridge FFI prima
    try {
      if (NativeVitalBridge.isInitialized) {
         return NativeVitalBridge.calculateVitals(payload.samples, payload.imagePixels, payload.width, payload.height);
      }
    } catch (e) {
      debugPrint("FFI error in isolate: $e");
    }

    // FALLBACK TEMPORANEO 100% DART
    // Dato che la build C# per Android NativeAOT è bloccata dalla mancanza dell'SDK Bionic,
    // eseguiamo la stessa matematica (FFT, Z-Score) in Dart per permetterti di testare la telecamera ORA.
    List<double> samples = payload.samples;
    int bufferSize = samples.length;
    double sum = 0;
    for (int i = 0; i < bufferSize; i++) sum += samples[i];
    double mean = sum / bufferSize;

    double varianceSum = 0;
    for (int i = 0; i < bufferSize; i++) {
      double diff = samples[i] - mean;
      varianceSum += diff * diff;
    }
    double stdDev = math.sqrt(varianceSum / bufferSize);

    if (stdDev < 0.0001) {
      return VitalResult(0, 0, 0, List.filled(bufferSize, 0.0), List.filled(bufferSize, 0.0));
    }

    List<double> normalized = List.filled(bufferSize, 0.0);
    for (int i = 0; i < bufferSize; i++) {
      normalized[i] = (samples[i] - mean) / stdDev;
    }

    // 1. Finestra di Hanning per ridurre la dispersione spettrale (Spectral Leakage)
    // 2. Zero-Padding a 1024 per aumentare la risoluzione frequenziale da 14 RPM a 1.7 RPM per bin!
    int fftSize = 1024;
    List<_Complex> complexBuffer = List.generate(fftSize, (i) {
      if (i < bufferSize) {
        // Hanning Window
        double multiplier = 0.5 * (1 - math.cos(2 * math.pi * i / (bufferSize - 1)));
        return _Complex(normalized[i] * multiplier, 0);
      } else {
        return _Complex(0, 0);
      }
    });

    _fft(complexBuffer);

    double maxRespMag = 0, maxCardioMag = 0;
    double dominantRespFreq = 0, dominantCardioFreq = 0;
    double freqResolution = 30.0 / fftSize; // 30 FPS / 1024 = 0.029 Hz per Bin

    double totalMag = 0;
    int binCount = 0;

    for (int i = 1; i <= fftSize ~/ 2; i++) {
      double freq = i * freqResolution;
      double mag = math.sqrt(complexBuffer[i].r * complexBuffer[i].r + complexBuffer[i].i * complexBuffer[i].i);
      
      totalMag += mag;
      binCount++;

      // Frequenza respiratoria ampliata fino a 1.2 Hz (72 RPM) per permettere la tracciatura dell'iperventilazione
      if (freq >= 0.15 && freq <= 1.2) { 
        if (mag > maxRespMag) {
          maxRespMag = mag;
          dominantRespFreq = freq;
        }
      } else if (freq >= 1.3 && freq <= 3.0) { // 78 - 180 BPM
        if (mag > maxCardioMag) {
          maxCardioMag = mag;
          dominantCardioFreq = freq;
        }
      }
    }

    double averageMag = totalMag / binCount;
    double respSNR = averageMag > 0 ? (maxRespMag / averageMag) : 0;
    double cardioSNR = averageMag > 0 ? (maxCardioMag / averageMag) : 0;

    // Se l'utente trattiene il respiro, nella banda c'è solo rumore bianco.
    // Un segnale periodico reale svetta sul rumore (SNR > 3.5).
    if (respSNR < 3.5) dominantRespFreq = 0.0;
    if (cardioSNR < 3.5) dominantCardioFreq = 0.0;

    List<double> respWave = List.filled(bufferSize, 0.0);
    List<double> cardioWave = List.filled(bufferSize, 0.0);
    for (int i = 0; i < bufferSize; i++) {
      respWave[i] = normalized[i] * 0.5; // Smoothing basilare per UI
      cardioWave[i] = normalized[i];
    }

    double confidence = (cardioSNR + respSNR) / 20.0; // SNR di 10 = 100% confidence
    confidence = confidence.clamp(0.0, 1.0);

    return VitalResult(
      dominantCardioFreq * 60.0,
      dominantRespFreq * 60.0,
      confidence,
      respWave,
      cardioWave,
    );
  }

  // Radix-2 Cooley-Tukey FFT in Dart
  static void _fft(List<_Complex> buffer) {
    int n = buffer.length;
    if (n <= 1) return;
    List<_Complex> even = List.generate(n ~/ 2, (i) => buffer[i * 2]);
    List<_Complex> odd = List.generate(n ~/ 2, (i) => buffer[i * 2 + 1]);
    _fft(even);
    _fft(odd);
    for (int k = 0; k < n ~/ 2; k++) {
      double t = -2 * math.pi * k / n;
      _Complex exp = _Complex(math.cos(t), math.sin(t));
      _Complex oddExp = _Complex(
        exp.r * odd[k].r - exp.i * odd[k].i,
        exp.r * odd[k].i + exp.i * odd[k].r,
      );
      buffer[k] = _Complex(even[k].r + oddExp.r, even[k].i + oddExp.i);
      buffer[k + n ~/ 2] = _Complex(even[k].r - oddExp.r, even[k].i - oddExp.i);
    }
  }
}

class _Complex {
  final double r;
  final double i;
  _Complex(this.r, this.i);
}
