using System;

namespace PediatricVitalEngine;

public class SidsAnalyzer
{
    private DateTime? _unsafePositionStartTime;
    private const int UnsafeDurationSeconds = 8;

    public (int PostureState, int SidsRiskFlag) AnalyzePostureAndRisk(float[] keypoints, int motionState)
    {
        // Se c'è un macro movimento, potremmo non avere una lettura stabile, resettiamo il timer
        if (motionState == 2)
        {
            _unsafePositionStartTime = null;
            // Supponiamo mantenga lo stato precedente o ritorni 0 temporaneamente.
            // Per questo modulo mock, restituiamo Supina.
            return (0, 0); 
        }

        int postureState = DeterminePosture(keypoints);
        int sidsRiskFlag = 0;

        // Regole di Rischio:
        // Se Prona (1) -> SidsRisk = 1
        // Se Viso Coperto (4) -> SidsRisk = 2
        bool isUnsafe = (postureState == 1 || postureState == 4);

        if (isUnsafe)
        {
            if (_unsafePositionStartTime == null)
            {
                _unsafePositionStartTime = DateTime.UtcNow;
            }
            else if ((DateTime.UtcNow - _unsafePositionStartTime.Value).TotalSeconds >= UnsafeDurationSeconds)
            {
                sidsRiskFlag = (postureState == 1) ? 1 : 2;
            }
        }
        else
        {
            _unsafePositionStartTime = null;
        }

        return (postureState, sidsRiskFlag);
    }

    private int DeterminePosture(float[] keypoints)
    {
        // Mock logic per determinare la postura dai keypoints facciali/corpo
        if (keypoints == null || keypoints.Length < 10)
        {
            // Se mancano i keypoints, simuliamo VISO COPERTO (4)
            return 4;
        }
        
        // Per il mock, restituiamo SUPINA (0) di default.
        // In un caso reale, controlleremmo le proporzioni tra naso, occhi, e orecchie.
        return 0; 
    }
}
