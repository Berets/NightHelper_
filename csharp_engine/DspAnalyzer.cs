using System;
using System.Linq;
using MathNet.Numerics.IntegralTransforms;
using MathNet.Numerics.Statistics;

namespace PediatricVitalEngine;

public class DspAnalyzer
{
    private const double SamplingRate = 30.0; // Assume 30 FPS for now

    public unsafe (double Rpm, double Bpm, double Confidence) AnalyzeSignal(float* signalBuffer, int signalSize, float* outResp, float* outCardio)
    {
        if (signalSize < 32 || signalBuffer == null)
            return (0.0, 0.0, 0.0);

        // Copy pointer data to double array for MathNet
        double[] rawData = new double[signalSize];
        for (int i = 0; i < signalSize; i++)
        {
            rawData[i] = signalBuffer[i];
        }

        // 1. Detrending (subtract mean)
        double mean = rawData.Average();
        for (int i = 0; i < signalSize; i++)
        {
            rawData[i] -= mean;
        }

        // Add Hanning window to reduce spectral leakage
        for (int i = 0; i < signalSize; i++)
        {
            rawData[i] *= 0.5 * (1 - Math.Cos(2 * Math.PI * i / (signalSize - 1)));
        }

        // Apply FFT
        // MathNet's ForwardReal transforms in-place. Size must be even.
        int fftSize = signalSize % 2 == 0 ? signalSize : signalSize - 1;
        double[] fftData = new double[fftSize];
        Array.Copy(rawData, fftData, fftSize);
        
        // Output array size will be N/2 + 1 complex numbers, but MathNet modifies in place:
        // [real0, realN/2, real1, imag1, real2, imag2...] (Format depends on version, let's use Complex array to be safe)
        System.Numerics.Complex[] complexData = new System.Numerics.Complex[fftSize];
        for (int i = 0; i < fftSize; i++)
        {
            complexData[i] = new System.Numerics.Complex(fftData[i], 0);
        }
        
        Fourier.Forward(complexData, FourierOptions.NoScaling);

        // Calculate magnitude spectrum
        int halfSize = fftSize / 2;
        double[] magnitudes = new double[halfSize];
        for (int i = 0; i < halfSize; i++)
        {
            magnitudes[i] = complexData[i].Magnitude;
        }

        // Find RPM (Respiration: 0.2 - 1.0 Hz -> 12 - 60 RPM)
        double rpm = FindPeakFrequency(magnitudes, fftSize, 0.2, 1.0) * 60.0;

        // Find BPM (Heart Rate: 1.0 - 3.0 Hz -> 60 - 180 BPM)
        double bpm = FindPeakFrequency(magnitudes, fftSize, 1.0, 3.0) * 60.0;

        // Confidence heuristic based on signal variance
        double variance = rawData.Variance();
        double confidence = variance > 0.01 ? 0.95 : (variance > 0.001 ? 0.70 : 0.30);

        // Fill out buffers for graphing
        if (outResp != null)
        {
            for (int i = 0; i < signalSize; i++)
            {
                outResp[i] = (float)rawData[i];
            }
        }

        if (outCardio != null)
        {
            for (int i = 0; i < signalSize; i++)
            {
                outCardio[i] = (float)(rawData[i] * 0.5); // Mock cardio wave scaling
            }
        }

        return (Math.Round(rpm, 1), Math.Round(bpm, 1), confidence);
    }

    private double FindPeakFrequency(double[] magnitudes, int fftSize, double minHz, double maxHz)
    {
        double resolutionHz = SamplingRate / fftSize;
        int minIndex = (int)(minHz / resolutionHz);
        int maxIndex = (int)(maxHz / resolutionHz);

        if (minIndex < 0) minIndex = 0;
        if (maxIndex >= magnitudes.Length) maxIndex = magnitudes.Length - 1;

        double maxMagnitude = 0;
        int peakIndex = minIndex;

        for (int i = minIndex; i <= maxIndex; i++)
        {
            if (magnitudes[i] > maxMagnitude)
            {
                maxMagnitude = magnitudes[i];
                peakIndex = i;
            }
        }

        return peakIndex * resolutionHz;
    }
}
