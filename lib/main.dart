import 'dart:io' show Platform;
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'flutter_integration/vital_service.dart';
import 'flutter_integration/native_vital_bridge.dart';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  List<CameraDescription> cameras = [];
  try {
    WakelockPlus.enable();
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Avviso: Dispositivo non supporta la camera o wakelock nativo: $e");
  }
  
  runApp(NightHelperApp(cameras: cameras));
}

class NightHelperApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const NightHelperApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Advanced Edge AI Scanner',
      
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primarySwatch: Colors.blueGrey,
      ),
      home: DashboardScreen(cameras: cameras),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const DashboardScreen({super.key, required this.cameras});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  CameraController? _controller;
  static const platform = MethodChannel('com.pediatric.scanner/ir');

  bool _isOledBlackActive = false;
  bool _isProcessingFrame = false;

  int _frameCount = 0;
  int _currentFps = 0;
  Timer? _fpsTimer;
  String _resolution = "Unknown";
  String _nativeStatus = "Inizializzazione...";
  
  // Dual-Mode (Day/Night)
  double _lastLuminance = 0.0;
  bool _isNightMode = true;

  // Buffer Circolare per C# FFI (128 campioni)
  final int _bufferSize = 128;
  late Float32List _signalBuffer;
  late Uint8List _artifactBuffer; // 0 = Segnale Pulito, 1 = Artefatto da Movimento (Rosso/Arancio)
  int _bufferIndex = 0;

  final ValueNotifier<int> _graphUpdateNotifier = ValueNotifier<int>(0);

  // Integrazione VitalService
  final VitalService _vitalService = VitalService();
  double _bpm = 0.0;
  double _rpm = 0.0;
  double _confidence = 0.0;
  int _sleepState = -1;
  double _sleepConfidence = 0.0;
  int _postureState = 0;
  int _sidsRiskFlag = 0;
  List<double> _cardioWave = [];
  List<double> _respWave = [];
  bool _cameraFailed = false;

  // --- VARIABILI PER FRAME DIFFERENCING E CLASSIFICAZIONE MOVIMENTO ---
  Uint8List? _prevFrameY; // Salva la griglia Y campionata del frame precedente
  
  // Stati di Movimento
  bool _isBodyMoving = false;
  bool _isHeadTracked = false;
  double _restlessnessIndex = 0.0; // Indice Irrequietezza Notturna [0 - 100]
  
  int _framesSinceLastMovement = 0;
  final int _roiRelockFrames = 45; // ~1.5 secondi a 30 FPS

  @override
  void initState() {
    super.initState();
    _signalBuffer = Float32List(_bufferSize);
    _artifactBuffer = Uint8List(_bufferSize);
    _vitalService.initialize();
    _initializeCamera();

    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentFps = _frameCount;
          _frameCount = 0;
        });
      }
    });
  }

  Future<void> _enableIRModeNatively() async {
    try {
      final String status = await platform.invokeMethod('enableIRMode');
      setState(() {
        _nativeStatus = status;
      });
    } on PlatformException catch (e) {
      setState(() {
        _nativeStatus = "Nativo: Non supportato (${e.message})";
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      debugPrint("Nessuna fotocamera trovata.");
      return;
    }

    final frontCamera = widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => widget.cameras.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.low, 
      enableAudio: false,
      imageFormatGroup: Platform.isWindows ? null : ImageFormatGroup.yuv420, 
    );

    try {
      await _controller?.initialize();
    } catch (e) {
      debugPrint("Errore critico fotocamera: $e");
      if (!mounted) return;
      setState(() {
         _cameraFailed = true;
      });
    }
    
    if (!mounted) return;

    try {
      await _controller?.setExposureMode(ExposureMode.auto);
      await _controller?.setFocusMode(FocusMode.locked);
    } catch (e) {
      debugPrint("Avviso: Focus/Esposizione manuale non supportati su questa webcam: $e");
    }

    _resolution = "${_controller?.value.previewSize?.width ?? 0} x ${_controller?.value.previewSize?.height ?? 0}";
    await _enableIRModeNatively();

    if (Platform.isWindows) {
      debugPrint("Avviso: startImageStream non è supportato dal plugin camera su Windows. Il video verrà mostrato ma i vitali andranno simulati.");
      // Invia valori mockati per testare la UI e il bridge su Desktop
      Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _rpm = 12.0 + (DateTime.now().second % 5);
          _sleepState = (_rpm > 15) ? 0 : 2; 
          _sleepConfidence = 0.85;
          _isBodyMoving = false;
        });
      });
    } else {
      _controller?.startImageStream((CameraImage image) {
        if (_isProcessingFrame) return;
        _isProcessingFrame = true;
        _frameCount++;
        
        _processFrameWithMotionDetection(image);
        
        _isProcessingFrame = false;
      });
    }

    setState(() {});
  }

  void _processFrameWithMotionDetection(CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    // Campionamento per prestazioni (1 pixel ogni step)
    const int step = 4;
    final int gridWidth = width ~/ step;
    final int gridHeight = height ~/ step;
    final int gridSize = gridWidth * gridHeight;

    // Inizializza il buffer del frame precedente se non esiste
    if (_prevFrameY == null || _prevFrameY!.length != gridSize) {
      _prevFrameY = Uint8List(gridSize);
    }
    
    // Buffer per inferenza ONNX (RGB intero, ridotto di step)
    final Uint8List imagePixels = Uint8List(gridWidth * gridHeight * 3);

    int sumY = 0;
    int sumG = 0;
    int sumR = 0;
    int diffPixelsCount = 0;
    int validPixels = 0;
    
    const int pixelDiffThreshold = 10; 
    int gridIndex = 0;

    if (image.format.group == ImageFormatGroup.bgra8888) {
      final Plane plane = image.planes[0];
      for (int y = 0; y < height; y += step) {
        for (int x = 0; x < width; x += step) {
          final int index = (y * plane.bytesPerRow) + (x * 4);
          int b = plane.bytes[index];
          int g = plane.bytes[index + 1];
          int r = plane.bytes[index + 2];
          
          int yValue = (0.299 * r + 0.587 * g + 0.114 * b).toInt();

          if (_frameCount > 1) {
            final int prevY = _prevFrameY![gridIndex];
            if ((yValue - prevY).abs() > pixelDiffThreshold) {
              diffPixelsCount++;
            }
          }
          _prevFrameY![gridIndex] = yValue;
          
          // Salva per ONNX (RGB)
          int pxIdx = gridIndex * 3;
          imagePixels[pxIdx] = r;
          imagePixels[pxIdx + 1] = g;
          imagePixels[pxIdx + 2] = b;

          gridIndex++;

          bool isInROI = x > (width * 0.3) && x < (width * 0.7) && y > (height * 0.3) && y < (height * 0.7);
          if (isInROI) {
            sumY += yValue;
            sumR += r;
            sumG += g;
            validPixels++;
          }
        }
      }
    } else if (image.format.group == ImageFormatGroup.yuv420) {
      final Plane yPlane = image.planes[0];
      final Plane uPlane = image.planes[1];
      final Plane vPlane = image.planes[2];
      final int yRowStride = yPlane.bytesPerRow;
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      for (int y = 0; y < height; y += step) {
        for (int x = 0; x < width; x += step) {
          final int yIndex = y * yRowStride + x;
          final int yValue = yPlane.bytes[yIndex];

          if (_frameCount > 1) {
            final int prevY = _prevFrameY![gridIndex];
            if ((yValue - prevY).abs() > pixelDiffThreshold) {
              diffPixelsCount++;
            }
          }
          _prevFrameY![gridIndex] = yValue;

          final int uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;
          final int uValue = uPlane.bytes[uvIndex];
          final int vValue = vPlane.bytes[uvIndex];

          final int cU = uValue - 128;
          final int cV = vValue - 128;
          int r = (yValue + 1.402 * cV).toInt().clamp(0, 255);
          int g = (yValue - 0.344136 * cU - 0.714136 * cV).toInt().clamp(0, 255);
          int b = (yValue + 1.772 * cU).toInt().clamp(0, 255);

          int pxIdx = gridIndex * 3;
          imagePixels[pxIdx] = r;
          imagePixels[pxIdx + 1] = g;
          imagePixels[pxIdx + 2] = b;

          gridIndex++;

          bool isInROI = x > (width * 0.3) && x < (width * 0.7) && y > (height * 0.3) && y < (height * 0.7);
          
          if (isInROI) {
            sumY += yValue;
            sumR += r;
            sumG += g;
            validPixels++;
          }
        }
      }
    } else {
      return; // Formato non supportato
    }

      // -- CALCOLO SEGNALE RESPIRATORIO NELLA ROI --
      final double avgY = validPixels > 0 ? sumY / validPixels : 0;
      double avgG = validPixels > 0 ? sumG / validPixels : 0;
      double avgR = validPixels > 0 ? sumR / validPixels : 1.0;
      if (avgR == 0) avgR = 1.0; 

      bool isNight = avgY < 20.0;
      double rawSignal = isNight ? avgY : (avgG / avgR);

      // Salva il segnale calcolato
      if (_isBodyMoving) {
        _artifactBuffer[_bufferIndex] = 1;
        _signalBuffer[_bufferIndex] = _bufferIndex > 0 ? _signalBuffer[_bufferIndex - 1] : rawSignal;
      } else {
        _artifactBuffer[_bufferIndex] = 0;
        _signalBuffer[_bufferIndex] = rawSignal;
      }

      // Avanzamento circolare
      _bufferIndex = (_bufferIndex + 1) % _bufferSize;
      _graphUpdateNotifier.value = _bufferIndex;

      // Invia i dati al processore C# tramite l'Isolate (circa 2 volte al secondo)
      if (_bufferIndex % 15 == 0) {
        _vitalService.processCameraFrames(_signalBuffer.toList(), imagePixels, gridWidth, gridHeight).then((result) {
          if (mounted) {
            setState(() {
              // Applica il motion state da YOLO (0=Micro/Fermo, 1=Meso, 2=Macro)
              if (result.motionState == 2) {
                _isBodyMoving = true;
                _isHeadTracked = false;
                _framesSinceLastMovement = 0;
              } else if (result.motionState == 1) {
                _isBodyMoving = false;
                _isHeadTracked = false;
                _framesSinceLastMovement = 0;
              } else {
                _isBodyMoving = false;
                _framesSinceLastMovement += 15;
                if (_framesSinceLastMovement > _roiRelockFrames) {
                  _isHeadTracked = true;
                }
              }

              // Smoothing UI (EMA) per evitare sbalzi improvvisi nei numeri
              if (result.bpm > 0) _bpm = (_bpm == 0.0) ? result.bpm : (_bpm * 0.8 + result.bpm * 0.2);
              if (result.rpm > 0) _rpm = (_rpm == 0.0) ? result.rpm : (_rpm * 0.8 + result.rpm * 0.2);
              
              _sleepState = result.sleepState;
              _sleepConfidence = result.sleepConfidence;
              _postureState = result.postureState;
              _sidsRiskFlag = result.sidsRiskFlag;
              
              _confidence = result.confidence;
              _cardioWave = result.cardioWave;
              _respWave = result.respWave;
            });
          }
        });
      }

      // Throttle Aggiornamenti UI Testuale
      if (isNight != _isNightMode || 
          _frameCount % 30 == 0) {
        
        Future.microtask(() {
          if (mounted) {
            setState(() {
              _isNightMode = isNight;
              _lastLuminance = avgY;
            });
          }
        });
      }
  }

  Future<void> _toggleOledBlack(bool enable) async {
    setState(() {
      _isOledBlackActive = enable;
    });

    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      if (enable) {
        await ScreenBrightness().setApplicationScreenBrightness(0.01);
      } else {
        await ScreenBrightness().resetApplicationScreenBrightness();
      }
    } catch (e) {
      debugPrint("Avviso luminosità: $e");
    }
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _controller?.stopImageStream();
    _controller?.dispose();
    _graphUpdateNotifier.dispose();
    
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        ScreenBrightness().resetApplicationScreenBrightness();
      } catch (_) {}
    }
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isOledBlackActive) {
      return GestureDetector(
        onDoubleTap: () => _toggleOledBlack(false),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Text(
              "Doppio tap per uscire",
              style: TextStyle(color: Colors.white.withAlpha(25), fontSize: 12),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("IR & rPPG Scanner 2.0"),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
            // ZONA TOP: Camera + Sovrimpressioni
            if (_cameraFailed)
              const Flexible(
                flex: 3, 
                child: Center(
                  child: Text("Videocamera non disponibile su Windows.\nModalità Simulazione (FFI Test) Attiva.", textAlign: TextAlign.center, style: TextStyle(color: Colors.orange))
                )
              )
            else if (_controller != null && _controller!.value.isInitialized)
              Flexible(
                flex: 3,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: _isBodyMoving ? Colors.redAccent 
                             : (!_isHeadTracked ? Colors.orangeAccent 
                             : (_isNightMode ? Colors.blueGrey : Colors.green.withAlpha(128))), 
                        width: 3
                      ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Stack(
                    children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CameraPreview(_controller!),
                          ),
                        ),
                        // MIRINO VISIVO
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.center,
                            child: FractionallySizedBox(
                              widthFactor: 0.4,
                              heightFactor: 0.4,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.greenAccent.withAlpha(128),
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
            else
              const Flexible(flex: 2, child: Center(child: CircularProgressIndicator())),

          // ZONA CENTRALE: Diagnostica Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildBadge(
                  "Postura AI", 
                  _getPostureString(_postureState), 
                  _getPostureColor(_postureState, _sidsRiskFlag)
                ),
                _buildBadge(
                  "Rischio SIDS", 
                  _sidsRiskFlag == 0 ? "SICURA" : (_sidsRiskFlag == 1 ? "ALLARME PRONA" : "ALLARME VISO"), 
                  _sidsRiskFlag == 0 ? Colors.green : Colors.red
                ),
                _buildBadge(
                  "Movimento", 
                  _isBodyMoving ? "MACRO" : "MICRO/FERMO", 
                  _isBodyMoving ? Colors.red : Colors.green
                ),
                _buildBadge(
                  "Irrequieto", 
                  "${_restlessnessIndex.toStringAsFixed(0)}%", 
                  _restlessnessIndex > 50 ? Colors.red : (_restlessnessIndex > 20 ? Colors.orange : Colors.green)
                ),
              ],
            ),
          ),

          // ZONA GRAFICO
          Flexible(
            flex: 2,
            fit: FlexFit.loose,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SleepStateCard(
                      state: _sleepState,
                      confidence: _sleepConfidence,
                    ),
                    const SizedBox(height: 12),
                    VitalCard(
                      title: 'RESPIRAZIONE',
                      value: _rpm > 0 ? _rpm.toStringAsFixed(0) : '--',
                      unit: 'RPM',
                      color: Colors.lightBlueAccent,
                      waveData: _respWave,
                      icon: const Icon(Icons.air, color: Colors.white, size: 32),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ZONA INFERIORE: Informazioni
          Flexible(
            flex: 1,
            fit: FlexFit.loose,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E1E),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Modalità:", style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                        _isNightMode ? "NOTTE (Meccanica Y)" : "GIORNO (rPPG G/R)", 
                        style: TextStyle(color: _isNightMode ? Colors.blueAccent : Colors.greenAccent, fontWeight: FontWeight.bold)
                      ),
                    ],
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent.withAlpha(30),
                      foregroundColor: Colors.redAccent,
                      minimumSize: const Size(double.infinity, 40),
                    ),
                    icon: const Icon(Icons.nightlight_round, size: 20),
                    label: const Text("Forza Schermo OLED Black"),
                    onPressed: () => _toggleOledBlack(true),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildBadge(String title, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withAlpha(40),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color),
          ),
          child: Text(
            value,
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  String _getPostureString(int state) {
    switch (state) {
      case 0: return "SUPINA";
      case 1: return "PRONA";
      case 2: return "LATERALE";
      case 3: return "ASSENTE";
      case 4: return "VISO COPERTO";
      default: return "SCONOSCIUTA";
    }
  }

  Color _getPostureColor(int state, int sidsRisk) {
    if (sidsRisk > 0) return Colors.red;
    if (state == 3) return Colors.grey;
    if (state == 2) return Colors.lightBlue;
    return Colors.green;
  }
}

/// CustomPainter per onda e gestione Artefatti (Macro/Meso Movimento)
class SignalWavePainter extends CustomPainter {
  final Float32List signalBuffer;
  final Uint8List artifactBuffer;
  final int headIndex;
  final Color defaultColor;

  SignalWavePainter({
    required this.signalBuffer,
    required this.artifactBuffer,
    required this.headIndex,
    required this.defaultColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (signalBuffer.isEmpty) return;

    final double stepX = size.width / signalBuffer.length;
    double minVal = double.infinity;
    double maxVal = double.negativeInfinity;
    
    for (int i = 0; i < signalBuffer.length; i++) {
      final v = signalBuffer[i];
      if (v == 0) continue; 
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }

    if (minVal == double.infinity || minVal == maxVal) return; 

    final double range = maxVal - minVal;

    bool isFirstPoint = true;
    double prevX = 0;
    double prevY = 0;

    // Disegniamo segmento per segmento per poter cambiare colore in base agli artefatti
    for (int i = 0; i < signalBuffer.length; i++) {
      int actualIndex = (headIndex + i) % signalBuffer.length;
      double value = signalBuffer[actualIndex];
      int isArtifact = artifactBuffer[actualIndex];
      
      if (value == 0 && i < signalBuffer.length - 1) continue; 
      
      double x = i * stepX;
      double normalized = (value - minVal) / range;
      double y = size.height - (normalized * size.height);
      y = y.clamp(5.0, size.height - 5.0);

      if (isFirstPoint) {
        prevX = x;
        prevY = y;
        isFirstPoint = false;
      } else {
        // Colore rosso/arancio se il campione è un artefatto da movimento
        Color segmentColor = isArtifact == 1 ? Colors.orangeAccent : defaultColor;
        
        final paint = Paint()
          ..color = segmentColor
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round;

        canvas.drawLine(Offset(prevX, prevY), Offset(x, y), paint);
        
        prevX = x;
        prevY = y;
      }
    }

    if (!isFirstPoint) {
      final headPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(prevX, prevY), 4.0, headPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SignalWavePainter oldDelegate) {
    return oldDelegate.headIndex != headIndex || oldDelegate.defaultColor != defaultColor;
  }
}

class VitalCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final Color color;
  final List<double> waveData;
  final Widget icon;

  const VitalCard({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.color,
    required this.waveData,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120, // Limite rigido per evitare infinite height layout error
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.5), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      icon,
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: color,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        unit,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: CustomPaint(
                  painter: WavePainter(waveData: waveData, waveColor: color),
                  size: Size.infinite,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WavePainter extends CustomPainter {
  final List<double> waveData;
  final Color waveColor;

  WavePainter({required this.waveData, required this.waveColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (waveData.isEmpty) return;

    final paint = Paint()
      ..color = waveColor
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    const double maxAmp = 3.0;
    
    final double stepX = size.width / (waveData.length - 1);
    final double centerY = size.height / 2;

    for (int i = 0; i < waveData.length; i++) {
      double x = i * stepX;
      double val = waveData[i].clamp(-maxAmp, maxAmp);
      double y = centerY - ((val / maxAmp) * centerY);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final glowPaint = Paint()
      ..color = waveColor.withOpacity(0.3)
      ..strokeWidth = 8.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant WavePainter oldDelegate) => true;
}
class SleepStateCard extends StatelessWidget {
  final int state;
  final double confidence;

  const SleepStateCard({Key? key, required this.state, required this.confidence}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    String title = 'INIZIALIZZAZIONE';
    Color color = Colors.grey;
    IconData icon = Icons.hourglass_empty;

    if (state == 0) { title = 'SVEGLIO'; color = Colors.orange; icon = Icons.wb_sunny; }
    else if (state == 1) { title = 'SONNO LEGGERO'; color = Colors.lightBlueAccent; icon = Icons.nights_stay; }
    else if (state == 2) { title = 'SONNO PROFONDO'; color = Colors.deepPurpleAccent; icon = Icons.bedtime; }
    else if (state == 3) { title = 'REM'; color = Colors.pinkAccent; icon = Icons.remove_red_eye; }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(80), width: 2),
      ),
      child: Row(
        children: [
          Container(
            width: 80,
            decoration: BoxDecoration(
              color: color.withAlpha(20),
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(14), bottomLeft: Radius.circular(14)),
            ),
            child: Center(
              child: Icon(icon, color: color, size: 40),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'STATO DEL SONNO (ONNX/Mock)',
                    style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Confidenza: %',
                    style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
