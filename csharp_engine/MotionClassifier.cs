using System;

namespace PediatricVitalEngine;

public class MotionClassifier
{
    private BoundingBox? _lastBox;
    private const float MacroThreshold = 0.15f;
    private const float MesoThreshold = 0.02f;

    public int Classify(BoundingBox? currentBox)
    {
        if (currentBox == null) return 0;
        if (_lastBox == null)
        {
            _lastBox = currentBox;
            return 0; // Fermo al primo frame
        }

        // Calcola lo spostamento del centroide e l'area
        float dx = currentBox.X - _lastBox.X;
        float dy = currentBox.Y - _lastBox.Y;
        double displacement = Math.Sqrt(dx * dx + dy * dy);

        _lastBox = currentBox;

        if (displacement > MacroThreshold)
            return 2; // Macro-Movimento
        if (displacement > MesoThreshold)
            return 1; // Meso-Movimento

        return 0; // Micro-Movimento / Fermo
    }
}
