import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// A small grayscale copy of one camera preview frame, kept in the sensor's
/// own orientation - every probe frame shares it, so they compare directly.
class ProbeFrame {
  const ProbeFrame(this.pixels, this.width, this.height);
  final Uint8List pixels;
  final int width;
  final int height;

  static const _targetLongSide = 320;

  /// Downsamples [image]'s luminance to about [_targetLongSide] pixels on
  /// the long side. Handles the YUV (Android, iOS 420) and BGRA (iOS default)
  /// stream formats; returns null for any other.
  static ProbeFrame? fromCameraImage(CameraImage image) {
    final plane = image.planes.first;
    final bgra = image.format.group == ImageFormatGroup.bgra8888;
    final isYuv = image.format.group == ImageFormatGroup.yuv420 ||
        image.format.group == ImageFormatGroup.nv21;
    if (!bgra && !isYuv) return null;
    final step = math.max(1, math.max(image.width, image.height) ~/ _targetLongSide);
    final w = image.width ~/ step, h = image.height ~/ step;
    final out = Uint8List(w * h);
    final src = plane.bytes;
    final stride = plane.bytesPerRow;
    for (var y = 0; y < h; y++) {
      final row = y * step * stride;
      for (var x = 0; x < w; x++) {
        if (bgra) {
          final i = row + x * step * 4;
          out[y * w + x] = (src[i] + 2 * src[i + 1] + src[i + 2]) >> 2;
        } else {
          out[y * w + x] = src[row + x * step];
        }
      }
    }
    return ProbeFrame(out, w, h);
  }
}

class OverlapReading {
  const OverlapReading({required this.referenceFeatures, required this.inliers, this.overlap});
  /// ORB keypoints found in the previous shot's preview frame.
  final int referenceFeatures;
  final int inliers;
  /// Fraction (0-1) of the current view that also shows the previous shot;
  /// null when no geometrically consistent match was found at all.
  final double? overlap;
}

/// How much of [current] shows the same scene as [reference] (the preview
/// frame at the moment the previous shot was taken): ORB features matched
/// with the Lowe ratio test, a RANSAC homography, then how far the view's
/// centre has moved. Rotation-invariant, so it doesn't care which way the
/// sensor is oriented. Cheap enough (~20 ms) to run a few times a second.
OverlapReading measureOverlap(ProbeFrame reference, ProbeFrame current) {
  final orb = cv.ORB.create(nFeatures: 800);
  final matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
  final refMat = cv.Mat.fromList(reference.height, reference.width, cv.MatType.CV_8UC1, reference.pixels);
  final curMat = cv.Mat.fromList(current.height, current.width, cv.MatType.CV_8UC1, current.pixels);
  final (refKp, refDesc) = orb.detectAndCompute(refMat, cv.Mat.empty());
  final (curKp, curDesc) = orb.detectAndCompute(curMat, cv.Mat.empty());
  final disposables = <dynamic>[orb, matcher, refMat, curMat, refKp, refDesc, curKp, curDesc];
  try {
    final referenceFeatures = refKp.length;
    if (refKp.length < 8 || curKp.length < 8) {
      return OverlapReading(referenceFeatures: referenceFeatures, inliers: 0);
    }
    final knn = matcher.knnMatch(curDesc, refDesc, 2);
    disposables.add(knn);
    final src = <double>[], dst = <double>[];
    for (var m = 0; m < knn.length; m++) {
      final pair = knn[m];
      if (pair.length < 2 || pair[0].distance >= 0.75 * pair[1].distance) continue;
      final a = curKp[pair[0].queryIdx], b = refKp[pair[0].trainIdx];
      src..add(a.x)..add(a.y);
      dst..add(b.x)..add(b.y);
    }
    final good = src.length ~/ 2;
    if (good < 10) return OverlapReading(referenceFeatures: referenceFeatures, inliers: 0);
    final srcMat = cv.Mat.fromList(good, 1, cv.MatType.CV_32FC2, src);
    final dstMat = cv.Mat.fromList(good, 1, cv.MatType.CV_32FC2, dst);
    final mask = cv.Mat.empty();
    final h = cv.findHomography(srcMat, dstMat, method: cv.RANSAC, ransacReprojThreshold: 4, mask: mask);
    disposables.addAll([srcMat, dstMat, mask, h]);
    final inliers = h.isEmpty ? 0 : mask.countNoneZero;
    if (inliers < _minProbeInliers) {
      return OverlapReading(referenceFeatures: referenceFeatures, inliers: inliers);
    }
    final hv = h.data.buffer.asFloat64List(h.data.offsetInBytes, 9);
    final cx = current.width / 2, cy = current.height / 2;
    final d = hv[6] * cx + hv[7] * cy + hv[8];
    final mx = (hv[0] * cx + hv[1] * cy + hv[2]) / d;
    final my = (hv[3] * cx + hv[4] * cy + hv[5]) / d;
    final overlap = (1 - (mx - reference.width / 2).abs() / reference.width).clamp(0.0, 1.0) *
        (1 - (my - reference.height / 2).abs() / reference.height).clamp(0.0, 1.0);
    return OverlapReading(referenceFeatures: referenceFeatures, inliers: inliers, overlap: overlap);
  } finally {
    for (final d in disposables) {
      d.dispose();
    }
  }
}

const _minProbeInliers = 12;

enum CheckLevel { ok, warn, block }

class CaptureIssue {
  const CaptureIssue(this.level, this.title, this.message);
  final CheckLevel level;
  final String title;
  final String message;
}

/// Below this, the stitcher is unlikely to find a visual match for the join.
const minGoodOverlap = 0.2;
const _maxTiltDeg = 10.0;
const _maxShake = 0.6; // m/s², accelerometer deviation from its running average

/// Everything wrong with the next panorama shot, checked live *before* it is
/// taken. [CheckLevel.block] means the shot can't be taken yet (wrong
/// heading); [CheckLevel.warn] means it can, but may not join cleanly.
List<CaptureIssue> panoramaCaptureIssues({
  required int frameIndex,
  required double targetDeg,
  required double toleranceDeg,
  double? relativeHeadingDeg,
  List<double>? gravity,
  List<double>? baseGravity,
  double shake = 0,
  OverlapReading? overlap,
}) {
  final issues = <CaptureIssue>[];
  var headingOnTarget = false;
  if (frameIndex > 0) {
    if (relativeHeadingDeg == null) {
      issues.add(const CaptureIssue(CheckLevel.warn, 'No compass',
          'Heading unavailable - joins rely on visual overlap alone'));
    } else {
      final diff = (relativeHeadingDeg - targetDeg + 540) % 360 - 180;
      headingOnTarget = diff.abs() <= toleranceDeg;
      if (!headingOnTarget) {
        issues.add(CaptureIssue(
          CheckLevel.block,
          'Wrong angle',
          'Turn ${diff < 0 ? 'right' : 'left'} ${diff.abs().round()}° to reach '
              '${targetDeg.round()}° (now ${relativeHeadingDeg.round()}°), without moving from this spot',
        ));
      }
    }
  }
  if (gravity != null && baseGravity != null) {
    final tilt = _angleBetweenDeg(gravity, baseGravity);
    if (tilt > _maxTiltDeg) {
      issues.add(CaptureIssue(CheckLevel.warn, 'Phone tilted',
          'Tilted ${tilt.round()}° compared with the first shot - hold it the same way'));
    }
  }
  if (shake > _maxShake) {
    issues.add(const CaptureIssue(CheckLevel.warn, 'Moving', 'Hold the phone still'));
  }
  if (frameIndex > 0 && overlap != null) {
    if (overlap.referenceFeatures < 30) {
      issues.add(const CaptureIssue(CheckLevel.warn, 'Little detail',
          'The previous shot has too little detail to check overlap; this join may rely on the compass'));
    } else if (overlap.overlap == null) {
      issues.add(CaptureIssue(CheckLevel.warn, 'No overlap',
          "Can't find the previous shot in view - "
              '${headingOnTarget ? 'this join will rely on the compass' : 'turn back toward it'}'));
    } else if (overlap.overlap! < minGoodOverlap) {
      issues.add(CaptureIssue(CheckLevel.warn, 'Low overlap',
          'Only ${(overlap.overlap! * 100).round()}% overlap with the previous shot - '
              '${headingOnTarget ? 'this join may rely on the compass' : 'turn back a little'}'));
    }
  }
  return issues;
}

double _angleBetweenDeg(List<double> a, List<double> b) {
  final dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  final na = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
  final nb = math.sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]);
  if (na == 0 || nb == 0) return 0;
  return math.acos((dot / (na * nb)).clamp(-1.0, 1.0)) * 180 / math.pi;
}
