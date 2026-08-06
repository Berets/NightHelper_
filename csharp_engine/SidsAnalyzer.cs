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
        if (keypoints == null || keypoints.Length < 17 * 3)
        {
            return 4; // VISO COPERTO
        }
        
        // Keypoints YOLOv8: [x, y, conf, x, y, conf...]
        // 0: Nose, 1: L-Eye, 2: R-Eye, 3: L-Ear, 4: R-Ear, 5: L-Shoulder, 6: R-Shoulder
        float noseConf = keypoints[2];
        float lEyeConf = keypoints[5];
        float rEyeConf = keypoints[8];
        float lEarConf = keypoints[11];
        float rEarConf = keypoints[14];
        float lShoulderConf = keypoints[17];
        float rShoulderConf = keypoints[20];

        float confThresh = 0.5f;

        bool hasNose = noseConf > confThresh;
        bool hasEars = lEarConf > confThresh || rEarConf > confThresh;
        bool hasShoulders = lShoulderConf > confThresh || rShoulderConf > confThresh;

        if (!hasNose && !hasEars)
        {
            if (hasShoulders) return 1; // PRONA (spalle visibili, faccia nascosta)
            return 4; // VISO COPERTO (niente viso, niente spalle)
        }

        if (hasNose)
        {
            // Se vedo solo un orecchio bene, probabilmente è girato di lato
            if ((lEarConf > confThresh && rEarConf < confThresh) || (rEarConf > confThresh && lEarConf < confThresh))
            {
                return 2; // LATERALE
            }
            return 0; // SUPINA
        }

        return 0; // Fallback
    }
}
