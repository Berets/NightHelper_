using System;
using System.Linq;
using System.Collections.Generic;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace NightHelper.NET
{
    public class SleepAnalyzer : IDisposable
    {
        private readonly InferenceSession _session;
        private readonly bool _isMockMode;

        public SleepAnalyzer(string modelPath)
        {
            if (string.IsNullOrEmpty(modelPath) || !System.IO.File.Exists(modelPath))
            {
                // Fallback a Mock Mode se il modello non è fornito
                _isMockMode = true;
                return;
            }

            try
            {
                SessionOptions options = new SessionOptions();
                // Aggiungere qui eventuali opzioni NPU (es. CoreML, NNAPI)
                _session = new InferenceSession(modelPath, options);
                _isMockMode = false;
            }
            catch (Exception)
            {
                _isMockMode = true; // Fallback di sicurezza in Native AOT
            }
        }

        // 0=Wake, 1=Light, 2=Deep, 3=REM, -1=Unknown
        public (int State, float Confidence) Analyze(float[] rpmHistory)
        {
            if (rpmHistory == null || rpmHistory.Length < 10)
                return (-1, 0.0f); // Dati insufficienti

            if (_isMockMode)
            {
                return RunMockInference(rpmHistory);
            }

            try
            {
                // Assumiamo che il modello prenda in input un tensore [1, N]
                var inputMeta = _session.InputMetadata;
                string inputName = inputMeta.Keys.First();
                
                var tensor = new DenseTensor<float>(rpmHistory, new[] { 1, rpmHistory.Length });
                var inputs = new List<NamedOnnxValue> { NamedOnnxValue.CreateFromTensor(inputName, tensor) };

                using var results = _session.Run(inputs);
                var output = results.First().AsTensor<float>();

                // Output atteso: [ProbWake, ProbLight, ProbDeep, ProbREM]
                float maxProb = -1.0f;
                int bestState = -1;
                for (int i = 0; i < 4; i++)
                {
                    float prob = output[0, i];
                    if (prob > maxProb)
                    {
                        maxProb = prob;
                        bestState = i;
                    }
                }

                return (bestState, maxProb);
            }
            catch (Exception)
            {
                return (-1, 0.0f);
            }
        }

        private (int State, float Confidence) RunMockInference(float[] rpmHistory)
        {
            // Euristiche fisiologiche di base per lo Sleep Staging da RPM
            float avg = rpmHistory.Average();
            float sumSq = rpmHistory.Sum(x => (x - avg) * (x - avg));
            float variance = sumSq / rpmHistory.Length;

            // REM: RPM molto irregolare (alta varianza)
            if (variance > 4.0f)
                return (3, 0.85f);
            
            // WAKE: RPM elevato
            if (avg > 18.0f)
                return (0, 0.90f);
            
            // DEEP SLEEP: RPM basso e regolarissimo
            if (avg < 14.5f && variance < 1.0f)
                return (2, 0.95f);

            // LIGHT SLEEP: Zona di transizione
            return (1, 0.70f);
        }

        public void Dispose()
        {
            _session?.Dispose();
        }
    }
}
