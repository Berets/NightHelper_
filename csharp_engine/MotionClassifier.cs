using System;

namespace PediatricVitalEngine;

public class MotionClassifier
{
    private BoundingBox? _lastBox;
    private float[]? _lastKeypoints;
    private const float MacroThreshold = 0.15f;
    private const float MesoThreshold = 0.02f; // Increased sensitivity for keypoints (normalized coordinates)

    public int Classify(BoundingBox? currentBox, float[]? currentKeypoints)
    {
        if (currentBox == null) return 0;
        
        float maxDisplacement = 0f;

        // 1. Calculate Bounding Box displacement (fallback/macro motion)
        if (_lastBox != null)
        {
            float dx = currentBox.X - _lastBox.X;
            float dy = currentBox.Y - _lastBox.Y;
            maxDisplacement = (float)Math.Sqrt(dx * dx + dy * dy);
        }

        // 2. Calculate Keypoint displacement (sensitive micro/meso motion)
        if (currentKeypoints != null && _lastKeypoints != null && currentKeypoints.Length == _lastKeypoints.Length)
        {
            for (int i = 0; i < currentKeypoints.Length; i += 3)
            {
                // Only consider keypoints with high confidence
                float confCurrent = currentKeypoints[i + 2];
                float confLast = _lastKeypoints[i + 2];

                if (confCurrent > 0.5f && confLast > 0.5f)
                {
                    float kx = currentKeypoints[i] - _lastKeypoints[i];
                    float ky = currentKeypoints[i + 1] - _lastKeypoints[i + 1];
                    float dist = (float)Math.Sqrt(kx * kx + ky * ky);
                    if (dist > maxDisplacement)
                    {
                        maxDisplacement = dist;
                    }
                }
            }
        }

        _lastBox = currentBox;
        
        if (currentKeypoints != null)
        {
            _lastKeypoints = new float[currentKeypoints.Length];
            Array.Copy(currentKeypoints, _lastKeypoints, currentKeypoints.Length);
        }

        if (maxDisplacement > MacroThreshold)
            return 2; // Macro-Movimento
        if (maxDisplacement > MesoThreshold)
            return 1; // Meso-Movimento

        return 0; // Micro-Movimento / Fermo
    }
}
