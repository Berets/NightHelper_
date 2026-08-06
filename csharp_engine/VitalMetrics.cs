using System.Runtime.InteropServices;

namespace PediatricVitalEngine;

[StructLayout(LayoutKind.Sequential)]
public struct VitalMetrics
{
    public double HeartRateBPM;       // Battiti Cardiaci / Minuto (Range: 78 - 180)
    public double RespiratoryRateRPM; // Respiri / Minuto (Range: 12 - 48)
    public double SignalConfidence;   // Rapporto Segnale/Rumore SNR (0.0 - 1.0)
    public int MotionState;           // 0 = Fermo, 1 = Meso-Movimento, 2 = Macro-Movimento
    public int ApneaRiskFlag;         // 0 = Normale, 1 = Respiro Debole, 2 = Apnea Rilevata (>10s)
    public int SidsRiskFlag;          // 0 = Posizione Sicura, 1 = Viso Coperto / Posizione Prona Pericolosa
    public float RoiX, RoiY, RoiW, RoiH; // Coordinate normalizzate della ROI trovata dall'AI
}
