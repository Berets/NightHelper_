import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';
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
  external int motionState;

  @ffi.Int32()
  external int apneaRiskFlag;

  @ffi.Int32()
  external int sidsRiskFlag;

  @ffi.Int32()
  external int postureState;

  @ffi.Float()
  external double roiX;

  @ffi.Float()
  external double roiY;

  @ffi.Float()
  external double roiW;

  @ffi.Float()
  external double roiH;
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
  final int postureState;
  final int sidsRiskFlag;

  VitalResult(
    this.bpm, 
    this.rpm, 
    this.confidence, 
    this.respWave, 
    this.cardioWave, {
    this.sleepState = -1,
    this.sleepConfidence = 0.0,
    this.postureState = 0,
    this.sidsRiskFlag = 0,
  });
}

// C: VitalMetrics calculate_vitals(float* buffer, float* outResp, float* outCardio, int32_t size, uint8_t* imagePixels, int32_t imgWidth, int32_t imgHeight)
typedef CalculateVitalsC = VitalMetricsStruct Function(
  ffi.Pointer<ffi.Float> buffer, 
  ffi.Pointer<ffi.Float> outResp, 
  ffi.Pointer<ffi.Float> outCardio, 
  ffi.Int32 size,
  ffi.Pointer<ffi.Uint8> imagePixels,
  ffi.Int32 imgWidth,
  ffi.Int32 imgHeight
);

// Dart
typedef CalculateVitalsDart = VitalMetricsStruct Function(
  ffi.Pointer<ffi.Float> buffer, 
  ffi.Pointer<ffi.Float> outResp, 
  ffi.Pointer<ffi.Float> outCardio, 
  int size,
  ffi.Pointer<ffi.Uint8> imagePixels,
  int imgWidth,
  int imgHeight
);

class NativeVitalBridge {
  static late final ffi.DynamicLibrary _lib;
  static late final CalculateVitalsDart _calculateVitals;
  static bool isInitialized = false;

  static void init() {
    if (isInitialized) return;

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
      
      isInitialized = true;
    } catch (e) {
      print("Avviso: Libreria nativa non trovata o caricamento fallito ($e). Uso fallback Dart puro.");
      isInitialized = false; // Forza il fallback Dart
    }
  }

  static VitalResult calculateVitals(List<double> samples, Uint8List imagePixels, int imgWidth, int imgHeight) {
    if (!isInitialized) init();

    if (samples.isEmpty) return VitalResult(0, 0, 0, [], []);

    final int size = samples.length;
    
    // Alloca memoria
    final ffi.Pointer<ffi.Float> inBuffer = calloc<ffi.Float>(size);
    final ffi.Pointer<ffi.Float> outResp = calloc<ffi.Float>(size);
    final ffi.Pointer<ffi.Float> outCardio = calloc<ffi.Float>(size);
    
    // Alloca memoria immagine
    final ffi.Pointer<ffi.Uint8> imgBuffer = calloc<ffi.Uint8>(imagePixels.length);

    try {
      for (int i = 0; i < size; i++) {
        inBuffer[i] = samples[i];
      }
      
      for (int i = 0; i < imagePixels.length; i++) {
        imgBuffer[i] = imagePixels[i];
      }

      // Esegue funzione nativa
      final VitalMetricsStruct resultStruct = _calculateVitals(inBuffer, outResp, outCardio, size, imgBuffer, imgWidth, imgHeight);
      
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
        cardioWave,
        postureState: resultStruct.postureState,
        sidsRiskFlag: resultStruct.sidsRiskFlag,
      );
    } finally {
      // Memory Free
      calloc.free(inBuffer);
      calloc.free(outResp);
      calloc.free(outCardio);
      calloc.free(imgBuffer);
    }
  }
}
