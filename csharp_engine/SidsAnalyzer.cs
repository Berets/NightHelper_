using System;

namespace PediatricVitalEngine;

public class SidsAnalyzer
{
    private DateTime? _unsafePositionStartTime;
    private const int UnsafeDurationSeconds = 8;

    public int CheckSidsRisk(float[] keypoints, int motionState)
    {
        // Se c'è un macro movimento, potremmo non avere una lettura stabile, resettiamo
        if (motionState == 2)
        {
            _unsafePositionStartTime = null;
            return 0;
        }

        bool isUnsafe = IsPositionUnsafe(keypoints);

        if (isUnsafe)
        {
            if (_unsafePositionStartTime == null)
            {
                _unsafePositionStartTime = DateTime.UtcNow;
            }
            else if ((DateTime.UtcNow - _unsafePositionStartTime.Value).TotalSeconds >= UnsafeDurationSeconds)
            {
                return 1; // SIDS Risk Flag (Viso Coperto / Prona per > 8s)
            }
        }
        else
        {
            _unsafePositionStartTime = null;
        }

        return 0;
    }

    private bool IsPositionUnsafe(float[] keypoints)
    {
        // Mock logic for determining if position is prone or face covered
        // In a real scenario, this would use facial keypoint visibility and orientation
        if (keypoints == null || keypoints.Length < 10)
        {
            return true; // No face detected might mean face covered
        }
        
        return false; // Assumed safe for dummy implementation
    }
}
