using System.Runtime.InteropServices;

namespace PediatricVitalEngine;

[StructLayout(LayoutKind.Sequential)]
public struct VitalMetrics
{
    // Biometria Vitale
    public double HeartRateBPM;       // Battiti Cardiaci / Minuto (Range: 78 - 180)
    public double RespiratoryRateRPM; // Respiri / Minuto (Range: 12 - 48)
    public double SignalConfidence;   // Indice SNR (0.0 - 1.0)
    
    // Gestione Movimento & Rischi
    public int MotionState;           // 0 = Fermo, 1 = Meso-Movimento, 2 = Macro-Movimento
    public int ApneaRiskFlag;         // 0 = Normale, 1 = Respiro Debole, 2 = Apnea (>10s)
    public int SidsRiskFlag;          // 0 = Sicuro, 1 = Posizione Prona (Pancia), 2 = Viso Coperto
    public int PostureState;          // 0 = Supina, 1 = Prona, 2 = Laterale, 3 = Lettino Vuoto
    
    // Tracking Spaziale AI Bounding Box (Coordinate normalizzate 0.0 - 1.0)
    public float RoiX;
    public float RoiY;
    public float RoiW;
    public float RoiH;
}
