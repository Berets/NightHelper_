using System;
using System.Collections.Generic;
using System.Linq;

namespace PediatricVitalEngine;

public class YoloPrediction
{
    public BoundingBox Box { get; set; } = new BoundingBox();
    public float Confidence { get; set; }
    public float[] Keypoints { get; set; } = Array.Empty<float>(); // [x1, y1, conf1, x2, y2, conf2...]
}

public static class YoloNms
{
    // Applies Non-Maximum Suppression to YOLOv8-pose outputs
    public static YoloPrediction? ProcessYoloOutput(float[] output, int numBoxes = 8400, int numClasses = 1, int numKeypoints = 17, float confThreshold = 0.5f, float iouThreshold = 0.45f)
    {
        // Output shape is [1, 4 + numClasses + numKeypoints*3, numBoxes]
        // For yolov8n-pose: 4 + 1 + 51 = 56. [1, 56, 8400]
        int rowLength = 4 + numClasses + (numKeypoints * 3);
        List<YoloPrediction> predictions = new List<YoloPrediction>();

        for (int i = 0; i < numBoxes; i++)
        {
            // In YOLOv8, the output is transposed. The memory layout is flat.
            // Row i, column j is at index j * numBoxes + i
            float maxClassConf = 0;
            int classId = 0;

            for (int c = 0; c < numClasses; c++)
            {
                float conf = output[(4 + c) * numBoxes + i];
                if (conf > maxClassConf)
                {
                    maxClassConf = conf;
                    classId = c;
                }
            }

            if (maxClassConf >= confThreshold)
            {
                float xc = output[0 * numBoxes + i];
                float yc = output[1 * numBoxes + i];
                float w = output[2 * numBoxes + i];
                float h = output[3 * numBoxes + i];

                float x1 = xc - w / 2;
                float y1 = yc - h / 2;

                float[] kpts = new float[numKeypoints * 3];
                for (int k = 0; k < numKeypoints * 3; k++)
                {
                    kpts[k] = output[(4 + numClasses + k) * numBoxes + i];
                }

                predictions.Add(new YoloPrediction
                {
                    Box = new BoundingBox { X = x1, Y = y1, Width = w, Height = h },
                    Confidence = maxClassConf,
                    Keypoints = kpts
                });
            }
        }

        if (predictions.Count == 0) return null;

        // Sort by confidence descending
        predictions = predictions.OrderByDescending(p => p.Confidence).ToList();

        // NMS
        List<YoloPrediction> result = new List<YoloPrediction>();
        while (predictions.Count > 0)
        {
            var best = predictions[0];
            result.Add(best);
            predictions.RemoveAt(0);

            predictions.RemoveAll(p => CalculateIoU(best.Box, p.Box) > iouThreshold);
        }

        return result.FirstOrDefault();
    }

    private static float CalculateIoU(BoundingBox a, BoundingBox b)
    {
        float x1 = Math.Max(a.X, b.X);
        float y1 = Math.Max(a.Y, b.Y);
        float x2 = Math.Min(a.X + a.Width, b.X + b.Width);
        float y2 = Math.Min(a.Y + a.Height, b.Y + b.Height);

        float intersectionArea = Math.Max(0, x2 - x1) * Math.Max(0, y2 - y1);
        float box1Area = a.Width * a.Height;
        float box2Area = b.Width * b.Height;

        return intersectionArea / (box1Area + box2Area - intersectionArea + 1e-6f);
    }
}
