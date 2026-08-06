import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

// Struct Nativa C# -> Dart FFI
final class VitalMetricsStruct extends ffi.Struct {
  @ffi.Double()
  external double heartRateBPM;

  @ffi.Double()
  external double respiratoryRateRPM;

  @ffi.Double()
  external double signalConfidence;

  @ffi.Int32()
  external int sleepState;

  @ffi.Double()
  external double sleepConfidence;
}

// Classe Dart di trasporto per il Service e la UI
class VitalResult {
  final double bpm;
  final double rpm;
  final double confidence;
  final List<double> respWave;
  final List<double> cardioWave;
  final int sleepState; // 0=Wake, 1=Light, 2=Deep, 3=REM, -1=Unknown
  final double sleepConfidence;

  VitalResult(
    this.bpm, 
    this.rpm, 
    this.confidence, 
    this.respWave, 
    this.cardioWave, {
    this.sleepState = -1,
    this.sleepConfidence = 0.0,
  });
}

// C: VitalMetrics calculate_vitals(float* buffer, float* outResp, float* outCardio, int32_t size)
typedef CalculateVitalsC = VitalMetricsStruct Function(
  ffi.Pointer<ffi.Float> buffer, 
  ffi.Pointer<ffi.Float> outResp, 
  ffi.Pointer<ffi.Float> outCardio, 
  ffi.Int32 size
);

// Dart
typedef CalculateVitalsDart = VitalMetricsStruct Function(
  ffi.Pointer<ffi.Float> buffer, 
  ffi.Pointer<ffi.Float> outResp, 
  ffi.Pointer<ffi.Float> outCardio, 
  int size
);

class NativeVitalBridge {
  static late final ffi.DynamicLibrary _lib;
  static late final CalculateVitalsDart _calculateVitals;
  static bool _isInitialized = false;

  static void init() {
    if (_isInitialized) return;

    try {
      if (Platform.isAndroid) {
        _lib = ffi.DynamicLibrary.open('libNightHelper.NET.so');
      } else if (Platform.isIOS) {
        _lib = ffi.DynamicLibrary.process();
      } else if (Platform.isWindows) {
        _lib = ffi.DynamicLibrary.open('NightHelper.NET.dll');
      } else {
        throw UnsupportedError('Piattaforma corrente non supportata per FFI.');
      }
      
      _calculateVitals = _lib
          .lookup<ffi.NativeFunction<CalculateVitalsC>>('calculate_vitals')
          .asFunction<CalculateVitalsDart>();
      
      _isInitialized = true;
    } catch (e) {
      print("Avviso: Libreria nativa non trovata o caricamento fallito ($e). Uso fallback Dart puro.");
      _isInitialized = false; // Forza il fallback Dart
    }
  }

  static VitalResult calculateVitals(List<double> samples) {
    if (!_isInitialized) init();

    if (samples.isEmpty) return VitalResult(0, 0, 0, [], []);

    final int size = samples.length;
    
    // Alloca memoria
    final ffi.Pointer<ffi.Float> inBuffer = calloc<ffi.Float>(size);
    final ffi.Pointer<ffi.Float> outResp = calloc<ffi.Float>(size);
    final ffi.Pointer<ffi.Float> outCardio = calloc<ffi.Float>(size);

    try {
      for (int i = 0; i < size; i++) {
        inBuffer[i] = samples[i];
      }

      // Esegue funzione nativa
      final VitalMetricsStruct resultStruct = _calculateVitals(inBuffer, outResp, outCardio, size);
      
      // Estrae grafici
      final List<double> respWave = List<double>.filled(size, 0.0);
      final List<double> cardioWave = List<double>.filled(size, 0.0);
      for (int i = 0; i < size; i++) {
        respWave[i] = outResp[i];
        cardioWave[i] = outCardio[i];
      }
      
      return VitalResult(
        resultStruct.heartRateBPM, 
        resultStruct.respiratoryRateRPM, 
        resultStruct.signalConfidence, 
        respWave, 
        cardioWave
      );
    } finally {
      // Memory Free
      calloc.free(inBuffer);
      calloc.free(outResp);
      calloc.free(outCardio);
    }
  }
}
