using System;
using System.Runtime.InteropServices;

namespace PediatricVitalEngine;

public static class EngineAPI
{
    private static OnnxInferencer? _inferencer;
    private static MotionClassifier _motionClassifier = new();
    private static SidsAnalyzer _sidsAnalyzer = new();
    
    // Inizializza il modello ONNX
    [UnmanagedCallersOnly(EntryPoint = "init_engine")]
    public static int InitEngine(IntPtr modelPathPtr)
    {
        try
        {
            string modelPath = Marshal.PtrToStringUTF8(modelPathPtr) ?? "";
            _inferencer = new OnnxInferencer(modelPath);
            return 1; // Success
        }
        catch
        {
            return 0; // Error
        }
    }

    private static DateTime? _lastValidRoiTime = null;
    private const int EmptyBedTimeoutSeconds = 5;

    [UnmanagedCallersOnly(EntryPoint = "calculate_vitals")]
    public static unsafe VitalMetrics CalculateVitals(
        float* signalBuffer, float* outResp, float* outCardio, int signalSize,
        byte* imagePixels, int imgWidth, int imgHeight)
    {
        VitalMetrics metrics = new VitalMetrics();
        
        if (_inferencer == null) return metrics;

        // 1. Esegui Inferenza ONNX (ROI e Keypoints)
        var result = _inferencer.ProcessFrame(imagePixels, imgWidth, imgHeight);
        
        // 2. Controllo "Lettino Vuoto" (Coordinate ROI perse > 5 sec)
        if (result.BoundingBox == null)
        {
            if (_lastValidRoiTime != null && (DateTime.UtcNow - _lastValidRoiTime.Value).TotalSeconds > EmptyBedTimeoutSeconds)
            {
                metrics.PostureState = 3; // Lettino Vuoto / Assente
                metrics.MotionState = 0;
                metrics.SidsRiskFlag = 0;
                return metrics; // Non possiamo calcolare nient'altro
            }
        }
        else
        {
            _lastValidRoiTime = DateTime.UtcNow;
            metrics.RoiX = result.BoundingBox.X;
            metrics.RoiY = result.BoundingBox.Y;
            metrics.RoiW = result.BoundingBox.Width;
            metrics.RoiH = result.BoundingBox.Height;
        }

        // 3. Classifica Movimento
        metrics.MotionState = _motionClassifier.Classify(result.BoundingBox);
        
        // 4. Analisi SIDS e Postura
        var (posture, riskFlag) = _sidsAnalyzer.AnalyzePostureAndRisk(result.Keypoints, metrics.MotionState);
        metrics.PostureState = posture;
        metrics.SidsRiskFlag = riskFlag;

        // Mock values for HR and RR based on typical pediatric ranges for now.
        // Pausa temporanea del calcolo se Macro-Movimento.
        if (metrics.MotionState == 2)
        {
            // Valori fittizi per indicare pausa/invalidità temporanea durante il movimento
            metrics.HeartRateBPM = 0;
            metrics.RespiratoryRateRPM = 0;
            metrics.SignalConfidence = 0.0;
        }
        else
        {
            metrics.HeartRateBPM = 110.5;
            metrics.RespiratoryRateRPM = 25.0;
            metrics.SignalConfidence = 0.95;
        }
        
        return metrics;
    }
}
