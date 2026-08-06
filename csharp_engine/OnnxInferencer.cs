using System;
using System.Linq;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace PediatricVitalEngine;

public class BoundingBox
{
    public float X { get; set; }
    public float Y { get; set; }
    public float Width { get; set; }
    public float Height { get; set; }
}

public class InferenceResult
{
    public BoundingBox? BoundingBox { get; set; }
    public float[] Keypoints { get; set; } = Array.Empty<float>();
}

public class OnnxInferencer : IDisposable
{
    private readonly InferenceSession _session;

    public OnnxInferencer(string modelPath)
    {
        var options = new SessionOptions();
        _session = new InferenceSession(modelPath, options);
    }

    public unsafe InferenceResult ProcessFrame(byte* rgbPixels, int width, int height)
    {
        // 1. Prepare tensor (YOLOv8 requires [1, 3, 640, 640] float tensor with normalized values 0-1)
        var tensor = new DenseTensor<float>(new[] { 1, 3, 640, 640 });
        
        if (rgbPixels != null && width > 0 && height > 0)
        {
            // Nearest neighbor scaling da width*height a 640x640
            float scaleX = (float)width / 640f;
            float scaleY = (float)height / 640f;

            for (int y = 0; y < 640; y++)
            {
                int srcY = (int)(y * scaleY);
                if (srcY >= height) srcY = height - 1;

                for (int x = 0; x < 640; x++)
                {
                    int srcX = (int)(x * scaleX);
                    if (srcX >= width) srcX = width - 1;

                    int srcIndex = (srcY * width + srcX) * 3;

                    tensor[0, 0, y, x] = rgbPixels[srcIndex] / 255f;     // R
                    tensor[0, 1, y, x] = rgbPixels[srcIndex + 1] / 255f; // G
                    tensor[0, 2, y, x] = rgbPixels[srcIndex + 2] / 255f; // B
                }
            }
        }

        var inputs = new List<NamedOnnxValue>
        {
            NamedOnnxValue.CreateFromTensor("images", tensor)
        };

        // 2. Run inference
        using var results = _session.Run(inputs);
        var outputTensor = results.First().AsTensor<float>();

        // 3. Post-process (NMS)
        float[] outputArray = outputTensor.ToArray();
        var bestPred = YoloNms.ProcessYoloOutput(outputArray, numBoxes: 8400, numClasses: 1, numKeypoints: 17, confThreshold: 0.5f, iouThreshold: 0.45f);

        if (bestPred == null)
        {
            return new InferenceResult { BoundingBox = null, Keypoints = Array.Empty<float>() };
        }

        // Normalize box coordinates (YOLO outputs in 640x640 pixel coordinates)
        bestPred.Box.X /= 640f;
        bestPred.Box.Y /= 640f;
        bestPred.Box.Width /= 640f;
        bestPred.Box.Height /= 640f;

        // Normalize keypoints (x, y)
        for (int i = 0; i < bestPred.Keypoints.Length; i += 3)
        {
            bestPred.Keypoints[i] /= 640f;     // x
            bestPred.Keypoints[i + 1] /= 640f; // y
        }

        return new InferenceResult
        {
            BoundingBox = bestPred.Box,
            Keypoints = bestPred.Keypoints
        };
    }

    public void Dispose()
    {
        _session?.Dispose();
    }
}
