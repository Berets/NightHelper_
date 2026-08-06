using System;
using System.Numerics;
using System.Runtime.InteropServices;

namespace PediatricVitalEngine
{
    [StructLayout(LayoutKind.Sequential)]
    public struct VitalMetrics 
    {
        public double HeartRateBPM;
        public double RespiratoryRateRPM;
        public double SignalConfidence;
        public int SleepState;
        public double SleepConfidence;
    }

    public static class VitalProcessor
    {
        const int FPS = 30;
        private static NightHelper.NET.SleepAnalyzer _analyzer = new NightHelper.NET.SleepAnalyzer("");
        private static List<float> _rpmHistory = new List<float>();

        [UnmanagedCallersOnly(EntryPoint = "init_sleep_analyzer")]
        public static void InitSleepAnalyzer(IntPtr pathPtr)
        {
            string path = Marshal.PtrToStringUTF8(pathPtr) ?? string.Empty;
            _analyzer?.Dispose();
            _analyzer = new NightHelper.NET.SleepAnalyzer(path);
            _rpmHistory.Clear();
        }

        [UnmanagedCallersOnly(EntryPoint = "calculate_vitals")]
        public static unsafe VitalMetrics CalculateVitals(float* bufferPtr, float* outRespWave, float* outCardioWave, int bufferSize)
        {
            VitalMetrics metrics = new VitalMetrics { HeartRateBPM = 0, RespiratoryRateRPM = 0, SignalConfidence = 0, SleepState = -1, SleepConfidence = 0 };

            if (bufferPtr == null || outRespWave == null || outCardioWave == null || bufferSize < 2)
            {
                return metrics;
            }

            // 1. Calcolo Statistiche (Media e Varianza)
            double sum = 0;
            for (int i = 0; i < bufferSize; i++) sum += bufferPtr[i];
            double mean = sum / bufferSize;

            double varianceSum = 0;
            for (int i = 0; i < bufferSize; i++)
            {
                double diff = bufferPtr[i] - mean;
                varianceSum += diff * diff;
            }
            double stdDev = Math.Sqrt(varianceSum / bufferSize);

            // Confidence decresce se il segnale è piatto (rumore) o troppo caotico (artefatti di movimento)
            if (stdDev < 0.0001)
            {
                for (int i = 0; i < bufferSize; i++) { outRespWave[i] = 0; outCardioWave[i] = 0; }
                metrics.SignalConfidence = 0.0;
                return metrics;
            }
            metrics.SignalConfidence = 1.0; // Semplificazione per ora

            // Z-Score Normalization
            float[] normalizedBuffer = new float[bufferSize];
            for (int i = 0; i < bufferSize; i++)
            {
                normalizedBuffer[i] = (float)((bufferPtr[i] - mean) / stdDev);
            }

            // Smoothing per l'Onda Respiratoria (Media Mobile Finestra Larga per basse frequenze)
            int respWindow = 5;
            for (int i = 0; i < bufferSize; i++)
            {
                double smoothedVal = 0;
                int count = 0;
                for (int j = Math.Max(0, i - respWindow / 2); j <= Math.Min(bufferSize - 1, i + respWindow / 2); j++)
                {
                    smoothedVal += normalizedBuffer[j];
                    count++;
                }
                outRespWave[i] = (float)(smoothedVal / count);
            }

            // Onda Cardiaca: Usiamo il segnale ad alta frequenza (Raw normalizzato o leggermente filtrato)
            for (int i = 0; i < bufferSize; i++)
            {
                outCardioWave[i] = normalizedBuffer[i];
            }

            // FFT Setup
            int fftSize = 1;
            while (fftSize < bufferSize) fftSize <<= 1;

            Complex[] complexBuffer = new Complex[fftSize];
            for (int i = 0; i < bufferSize; i++) complexBuffer[i] = new Complex(normalizedBuffer[i], 0);
            for (int i = bufferSize; i < fftSize; i++) complexBuffer[i] = Complex.Zero;

            // FFT
            FFT(complexBuffer);

            // Analisi Spettrale (Due Bande Separate)
            double maxRespMag = 0, maxCardioMag = 0;
            double dominantRespFreq = 0, dominantCardioFreq = 0;
            double freqResolution = (double)FPS / fftSize;

            for (int i = 1; i <= fftSize / 2; i++)
            {
                double freq = i * freqResolution;
                double magnitude = complexBuffer[i].Magnitude;

                // Banda Respiratoria: 0.2 - 0.8 Hz (12 - 48 RPM)
                if (freq >= 0.2 && freq <= 0.8)
                {
                    if (magnitude > maxRespMag) { maxRespMag = magnitude; dominantRespFreq = freq; }
                }
                // Banda Cardiaca: 1.3 - 3.0 Hz (78 - 180 BPM)
                else if (freq >= 1.3 && freq <= 3.0)
                {
                    if (magnitude > maxCardioMag) { maxCardioMag = magnitude; dominantCardioFreq = freq; }
                }
            }

            metrics.RespiratoryRateRPM = dominantRespFreq * 60.0;
            metrics.HeartRateBPM = dominantCardioFreq * 60.0;
            
            // INTEGRAZIONE AI (SLEEP STAGING VIA ONNX)
            if (metrics.RespiratoryRateRPM > 0)
            {
                _rpmHistory.Add((float)metrics.RespiratoryRateRPM);
                if (_rpmHistory.Count > 30) _rpmHistory.RemoveAt(0); // Ultimi 30 campioni (~15 sec)

                if (_rpmHistory.Count >= 10 && _analyzer != null)
                {
                    var (state, conf) = _analyzer.Analyze(_rpmHistory.ToArray());
                    metrics.SleepState = state;
                    metrics.SleepConfidence = conf;
                }
            }

            return metrics;
        }

        private static void FFT(Complex[] data)
        {
            int n = data.Length;
            int m = (int)Math.Log2(n);

            for (int i = 0; i < n; i++)
            {
                int j = ReverseBits(i, m);
                if (j > i)
                {
                    Complex temp = data[i]; data[i] = data[j]; data[j] = temp;
                }
            }

            for (int s = 1; s <= m; s++)
            {
                int m_s = 1 << s;
                double theta = -2 * Math.PI / m_s;
                Complex wm = new Complex(Math.Cos(theta), Math.Sin(theta));

                for (int k = 0; k < n; k += m_s)
                {
                    Complex w = Complex.One;
                    for (int j = 0; j < m_s / 2; j++)
                    {
                        Complex t = w * data[k + j + m_s / 2];
                        Complex u = data[k + j];
                        data[k + j] = u + t;
                        data[k + j + m_s / 2] = u - t;
                        w *= wm;
                    }
                }
            }
        }

        private static int ReverseBits(int n, int bitsCount)
        {
            int reversed = 0;
            for (int i = 0; i < bitsCount; i++)
            {
                if ((n & (1 << i)) != 0) reversed |= (1 << ((bitsCount - 1) - i));
            }
            return reversed;
        }
    }
}
