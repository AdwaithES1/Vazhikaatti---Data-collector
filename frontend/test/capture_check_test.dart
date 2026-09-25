import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vazhikatti_dataset_collector/services/panorama/capture_check.dart';

/// A wide random-blob texture, and a [width]-wide window into it starting at
/// [left] - standing in for the camera preview as the phone turns.
Uint8List _scene(int w, int h) {
  final rng = math.Random(11);
  final px = Uint8List(w * h);
  for (var i = 0; i < 900; i++) {
    final cx = rng.nextInt(w), cy = rng.nextInt(h), r = 2 + rng.nextInt(9);
    final v = rng.nextInt(256);
    for (var y = math.max(0, cy - r); y < math.min(h, cy + r); y++) {
      for (var x = math.max(0, cx - r); x < math.min(w, cx + r); x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) px[y * w + x] = v;
      }
    }
  }
  return px;
}

ProbeFrame _window(Uint8List scene, int sceneW, int h, int left, int width) {
  final out = Uint8List(width * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < width; x++) {
      out[y * width + x] = scene[y * sceneW + left + x];
    }
  }
  return ProbeFrame(out, width, h);
}

void main() {
  const sceneW = 1000, h = 240, w = 320;
  final scene = _scene(sceneW, h);

  group('measureOverlap', () {
    test('a small turn keeps most of the previous view', () {
      final reading = measureOverlap(_window(scene, sceneW, h, 100, w), _window(scene, sceneW, h, 180, w));
      expect(reading.overlap, closeTo(0.75, 0.05));
    });

    test('a big turn leaves little overlap', () {
      final reading = measureOverlap(_window(scene, sceneW, h, 100, w), _window(scene, sceneW, h, 380, w));
      expect(reading.overlap == null || reading.overlap! < minGoodOverlap, isTrue);
    });

    test('no overlap at all finds no match', () {
      final reading = measureOverlap(_window(scene, sceneW, h, 0, w), _window(scene, sceneW, h, 600, w));
      expect(reading.overlap, isNull);
    });

    test('a blank previous view is reported as lacking detail', () {
      final blank = ProbeFrame(Uint8List(w * h), w, h);
      final reading = measureOverlap(blank, _window(scene, sceneW, h, 0, w));
      expect(reading.referenceFeatures, lessThan(30));
      expect(reading.overlap, isNull);
    });
  });

  group('panoramaCaptureIssues', () {
    test('on target, level, still and overlapping: nothing to flag', () {
      final issues = panoramaCaptureIssues(
        frameIndex: 2,
        targetDeg: 90,
        toleranceDeg: 6,
        relativeHeadingDeg: 88,
        gravity: [0, 9.8, 0.3],
        baseGravity: [0, 9.8, 0],
        overlap: const OverlapReading(referenceFeatures: 400, inliers: 80, overlap: 0.4),
      );
      expect(issues, isEmpty);
    });

    test('short of the target blocks the shot and says which way to turn', () {
      final issues = panoramaCaptureIssues(
        frameIndex: 1,
        targetDeg: 45,
        toleranceDeg: 6,
        relativeHeadingDeg: 30,
      );
      expect(issues.single.level, CheckLevel.block);
      expect(issues.single.message, startsWith('Turn right 15°'));
    });

    test('past the target across 0°/360° says turn left', () {
      final issues = panoramaCaptureIssues(
        frameIndex: 7,
        targetDeg: 315,
        toleranceDeg: 6,
        relativeHeadingDeg: 340,
      );
      expect(issues.single.message, startsWith('Turn left 25°'));
    });

    test('tilt, shake and low overlap warn without blocking', () {
      final issues = panoramaCaptureIssues(
        frameIndex: 3,
        targetDeg: 135,
        toleranceDeg: 6,
        relativeHeadingDeg: 135,
        gravity: [0, 9.8, 3.5],
        baseGravity: [0, 9.8, 0],
        shake: 2,
        overlap: const OverlapReading(referenceFeatures: 400, inliers: 20, overlap: 0.1),
      );
      expect(issues.map((i) => i.title), ['Phone tilted', 'Moving', 'Low overlap']);
      expect(issues.every((i) => i.level == CheckLevel.warn), isTrue);
    });

    test('the first shot has nothing to compare against', () {
      final issues = panoramaCaptureIssues(frameIndex: 0, targetDeg: 0, toleranceDeg: 6);
      expect(issues, isEmpty);
    });
  });
}
