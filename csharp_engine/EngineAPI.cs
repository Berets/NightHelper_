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

    [UnmanagedCallersOnly(EntryPoint = "calculate_vitals")]
    public static VitalMetrics CalculateVitals(IntPtr frameData, int width, int height)
    {
        VitalMetrics metrics = new VitalMetrics();
        
        if (_inferencer == null) return metrics;

        // 1. Esegui Inferenza ONNX (ROI e Keypoints)
        var result = _inferencer.ProcessFrame(frameData, width, height);
        
        // 2. Classifica Movimento
        metrics.MotionState = _motionClassifier.Classify(result.BoundingBox);
        
        // 3. Analisi SIDS (Orientamento Testa)
        metrics.SidsRiskFlag = _sidsAnalyzer.CheckSidsRisk(result.Keypoints, metrics.MotionState);
        
        // 4. Aggiorna ROI nella struct
        if (result.BoundingBox != null)
        {
            metrics.RoiX = result.BoundingBox.X;
            metrics.RoiY = result.BoundingBox.Y;
            metrics.RoiW = result.BoundingBox.Width;
            metrics.RoiH = result.BoundingBox.Height;
        }

        // Mock values for HR and RR based on typical pediatric ranges for now,
        // typically this would be handled by a DSP/FFT pipeline over time.
        metrics.HeartRateBPM = 110.5;
        metrics.RespiratoryRateRPM = 25.0;
        metrics.SignalConfidence = 0.95;
        
        return metrics;
    }
}
