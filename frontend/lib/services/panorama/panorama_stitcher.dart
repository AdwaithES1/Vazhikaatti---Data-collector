import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Raised when a stage of the stitching pipeline cannot produce a trustworthy
/// result. For the single-image stages (`load`, `features`), [pair] is the
/// 1-based index of the failing image itself. For every other stage it is the
/// 1-based index of the image pair (image `pair` and `pair + 1`).
///
/// A pairwise (`matching`/`ransac`/`homography`) failure is only raised when
/// the compass-heading fallback also could not be used for that pair (no
/// heading recorded for one of the two images) - see [PanoramaStitcher.stitch].
class PanoramaStitchException implements Exception {
  const PanoramaStitchException(this.stage, this.message, {this.pair});
  final String stage;
  final String message;
  final int? pair;
  static const _singleImageStages = {'load', 'features'};
  @override
  String toString() {
    if (pair == null) return '$stage: $message';
    final where = _singleImageStages.contains(stage)
        ? 'image $pair'
        : 'images $pair→${pair! + 1}';
    return '$stage ($where): $message';
  }
}

class PanoramaStitchResult {
  const PanoramaStitchResult({
    required this.path,
    required this.width,
    required this.height,
    required this.keypointCount,
    required this.totalMatches,
    required this.goodMatches,
    required this.inlierCount,
    required this.sensorFallbackPairs,
  });
  final String path;
  final int width;
  final int height;
  final int keypointCount;
  final int totalMatches;
  final int goodMatches;
  final int inlierCount;
  /// Number of adjacent pairs (out of images.length - 1) that could not be
  /// geometrically validated by SIFT/RANSAC and were instead positioned using
  /// the compass heading recorded for each image. 0 means every link in the
  /// panorama was validated by feature matching.
  final int sensorFallbackPairs;
  double get inlierRatio => goodMatches == 0 ? 0 : inlierCount / goodMatches;
}

/// Classical panorama stitching:
/// cylindrical pre-warp → SIFT → kNN descriptor matching → Lowe ratio test →
/// RANSAC homography per neighbouring pair → chained perspective warp →
/// distance-weighted (feather) blending.
///
/// When a pair's matches don't clear the ratio test, RANSAC can't find a
/// homography, or the homography it finds is geometrically implausible, the
/// pair is positioned using the compass heading already recorded for each
/// image (a pure horizontal shift in the cylindrical projection, since a
/// heading difference is exactly a yaw rotation) instead of being rejected
/// outright. This still uses only the existing compass sensor already
/// collected for every capture; it does not add feature recognition beyond
/// SIFT/RANSAC. The pipeline only fails outright when a pair has no usable
/// heading for one of its two images, or a whole image can't be decoded or
/// has essentially no texture at all.
class PanoramaStitcher {
  static const ratioThreshold = 0.75;
  static const ransacThreshold = 3.0;
  static const descriptorDimension = 128;
  static const _minGoodMatches = 15;
  static const _minInliers = 12;
  static const _minInlierRatio = 0.3;
  static const _workingLongSide = 1280;
  // Phone cameras are ~60° wide; used only for the cylindrical pre-warp.
  static const _assumedHorizontalFov = 60 * math.pi / 180;

  /// Stitches [imagePaths] (ordered by capture angle) into one JPEG at
  /// [outputPath]. [headingsDeg], if given, must be the same length as
  /// [imagePaths] - the compass heading (degrees) recorded for each image, or
  /// null for images without one; it is only consulted as a fallback for a
  /// pair that fails geometric validation. Runs in a background isolate;
  /// throws [PanoramaStitchException] on any failure.
  static Future<PanoramaStitchResult> stitch(
    List<String> imagePaths,
    String outputPath, {
    List<double?>? headingsDeg,
  }) => Isolate.run(() => _stitch(imagePaths, outputPath, headingsDeg));
}

class _Frame {
  _Frame(this.image, this.mask, this.keypoints, this.descriptors, this.f, this.headingDeg);
  final cv.Mat image;
  final cv.Mat mask;
  final cv.VecKeyPoint keypoints;
  final cv.Mat descriptors;
  final double f;
  final double? headingDeg;
}

/// Result of matching+RANSAC for one pair, before the caller decides whether
/// it is trustworthy enough to use.
class _PairAttempt {
  const _PairAttempt({
    required this.totalMatches,
    required this.good,
    this.homography,
    this.inliers = 0,
    this.failStage,
    this.failReason,
  });
  final int totalMatches;
  final int good;
  final List<double>? homography;
  final int inliers;
  final String? failStage;
  final String? failReason;
}

PanoramaStitchResult _stitch(
  List<String> paths,
  String outputPath,
  List<double?>? headingsDeg,
) {
  if (paths.length < 2) {
    throw const PanoramaStitchException('input', 'At least 2 images required');
  }
  if (headingsDeg != null && headingsDeg.length != paths.length) {
    throw const PanoramaStitchException(
      'input',
      'headingsDeg must be the same length as imagePaths',
    );
  }
  final sift = cv.SIFT.create(nfeatures: 4000);
  final matcher = cv.BFMatcher.create(type: cv.NORM_L2);
  final frames = <_Frame>[];
  try {
    return _stitchFrames(paths, outputPath, headingsDeg, sift, matcher, frames);
  } finally {
    // Runs on every exit path (success or a PanoramaStitchException), so a
    // failed/retried stitch never leaks the native Mats/keypoints/descriptors
    // of the frames that were already prepared.
    for (final f in frames) {
      f.image.dispose();
      f.mask.dispose();
      f.keypoints.dispose();
      f.descriptors.dispose();
    }
  }
}

PanoramaStitchResult _stitchFrames(
  List<String> paths,
  String outputPath,
  List<double?>? headingsDeg,
  cv.SIFT sift,
  cv.BFMatcher matcher,
  List<_Frame> frames,
) {
  var keypointCount = 0;
  for (var i = 0; i < paths.length; i++) {
    final frame = _prepare(paths[i], i + 1, sift, headingsDeg?[i]);
    keypointCount += frame.keypoints.length;
    frames.add(frame);
  }

  // Homography of each image into the previous image's frame, chained to
  // image 0.
  final global = <List<double>>[_identity];
  var totalMatches = 0, goodMatches = 0, inlierCount = 0, sensorFallbackPairs = 0;
  for (var i = 1; i < frames.length; i++) {
    final pair = i; // images i and i+1 (1-based)
    final attempt = _matchAndValidate(frames[i], frames[i - 1], matcher);
    totalMatches += attempt.totalMatches;

    var hv = attempt.homography;
    if (hv != null) {
      goodMatches += attempt.good;
      inlierCount += attempt.inliers;
    } else {
      final headingCur = frames[i].headingDeg;
      final headingPrev = frames[i - 1].headingDeg;
      if (headingCur == null || headingPrev == null) {
        // No compass fallback available for this pair: the same failure the
        // pure-vision pipeline always reported.
        throw PanoramaStitchException(
          attempt.failStage!,
          attempt.failReason!,
          pair: pair,
        );
      }
      hv = _compassHomography(frames[i - 1].f, headingPrev, headingCur);
      sensorFallbackPairs++;
      goodMatches += attempt.good; // still informational, not a validated link
    }
    global.add(_mul(global[i - 1], hv));
  }

  // Canvas bounds from the warped image corners.
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (var i = 0; i < frames.length; i++) {
    final w = frames[i].image.cols.toDouble(), h = frames[i].image.rows;
    for (final c in [
      [0.0, 0.0],
      [w, 0.0],
      [w, h.toDouble()],
      [0.0, h.toDouble()],
    ]) {
      final p = _apply(global[i], c[0], c[1]);
      minX = math.min(minX, p[0]);
      maxX = math.max(maxX, p[0]);
      minY = math.min(minY, p[1]);
      maxY = math.max(maxY, p[1]);
    }
  }
  final width = (maxX - minX).ceil(), height = (maxY - minY).ceil();
  if (!minX.isFinite ||
      !minY.isFinite ||
      width < frames.first.image.cols ||
      width > 16000 ||
      height < 1 ||
      height > 4000) {
    throw PanoramaStitchException(
      'warp',
      'implausible panorama canvas ${width}x$height',
    );
  }
  final shift = <double>[1, 0, -minX, 0, 1, -minY, 0, 0, 1];

  // Feather blending: weight = distance to the image border.
  var acc = cv.Mat.zeros(height, width, cv.MatType.CV_32FC3);
  var weights = cv.Mat.zeros(height, width, cv.MatType.CV_32FC1);
  for (var i = 0; i < frames.length; i++) {
    final m = cv.Mat.fromList(3, 3, cv.MatType.CV_64FC1, _mul(shift, global[i]));
    final warped = cv.warpPerspective(frames[i].image, m, (width, height));
    final warpedMask = cv.warpPerspective(
      frames[i].mask,
      m,
      (width, height),
      flags: cv.INTER_NEAREST,
    );
    final (dist, labels) = cv.distanceTransform(
      warpedMask,
      cv.DIST_L2,
      3,
      cv.DIST_LABEL_CCOMP,
    );
    final dist32 = dist.type == cv.MatType.CV_32FC1
        ? dist
        : dist.convertTo(cv.MatType.CV_32FC1);
    final w3 = cv.merge(cv.VecMat.fromList([dist32, dist32, dist32]));
    final color32 = warped.convertTo(cv.MatType.CV_32FC3);
    final weighted = cv.multiply(color32, w3);
    final newAcc = cv.add(acc, weighted);
    final newWeights = cv.add(weights, dist32);
    for (final mat in [m, warped, warpedMask, dist, labels, w3, color32, weighted, acc, weights]) {
      mat.dispose();
    }
    if (!identical(dist32, dist)) dist32.dispose();
    acc = newAcc;
    weights = newWeights;
  }
  final w3 = cv.merge(cv.VecMat.fromList([weights, weights, weights]));
  final blended = cv.divide(acc, w3);
  final result = blended.convertTo(cv.MatType.CV_8UC3);

  cv.imwrite(
    outputPath,
    result,
    params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 92]),
  );
  for (final mat in [acc, weights, w3, blended, result]) {
    mat.dispose();
  }
  // frames (image/mask/keypoints/descriptors) are disposed by the caller's
  // finally block, on both this success path and every failure path above.

  // Validate the file on disk before reporting success.
  final check = cv.imread(outputPath);
  final ok =
      !check.isEmpty &&
      check.cols == width &&
      check.rows == height &&
      cv.cvtColor(check, cv.COLOR_BGR2GRAY).countNoneZero > width * height * 0.3;
  final openedW = check.cols, openedH = check.rows;
  check.dispose();
  if (!ok) {
    throw PanoramaStitchException(
      'validation',
      'stitched file is unreadable, wrong size (${openedW}x$openedH) or mostly empty',
    );
  }
  return PanoramaStitchResult(
    path: outputPath,
    width: width,
    height: height,
    keypointCount: keypointCount,
    totalMatches: totalMatches,
    goodMatches: goodMatches,
    inlierCount: inlierCount,
    sensorFallbackPairs: sensorFallbackPairs,
  );
}

/// Runs kNN matching + the Lowe ratio test + RANSAC homography estimation for
/// one adjacent pair, returning a validated homography, or (via [failReason])
/// why it isn't trustworthy - never throws, so the caller can decide whether
/// a compass fallback is available before giving up on the pair.
_PairAttempt _matchAndValidate(_Frame cur, _Frame prev, cv.BFMatcher matcher) {
  final knn = matcher.knnMatch(cur.descriptors, prev.descriptors, 2);
  var totalMatches = 0;
  final src = <double>[], dst = <double>[];
  try {
    for (var m = 0; m < knn.length; m++) {
      final pairMatches = knn[m];
      if (pairMatches.length < 2) continue;
      totalMatches++;
      if (pairMatches[0].distance <
          PanoramaStitcher.ratioThreshold * pairMatches[1].distance) {
        final a = cur.keypoints[pairMatches[0].queryIdx];
        final b = prev.keypoints[pairMatches[0].trainIdx];
        src..add(a.x)..add(a.y);
        dst..add(b.x)..add(b.y);
      }
    }
  } finally {
    knn.dispose();
  }
  final good = src.length ~/ 2;
  if (good < PanoramaStitcher._minGoodMatches) {
    return _PairAttempt(
      totalMatches: totalMatches,
      good: good,
      failStage: 'matching',
      failReason:
          'only $good matches survived the ratio test '
          '(need ${PanoramaStitcher._minGoodMatches}); not enough overlap',
    );
  }

  final srcMat = cv.Mat.fromList(good, 1, cv.MatType.CV_32FC2, src);
  final dstMat = cv.Mat.fromList(good, 1, cv.MatType.CV_32FC2, dst);
  final inlierMask = cv.Mat.empty();
  try {
    final h = cv.findHomography(
      srcMat,
      dstMat,
      method: cv.RANSAC,
      ransacReprojThreshold: PanoramaStitcher.ransacThreshold,
      mask: inlierMask,
    );
    try {
      if (h.isEmpty) {
        return _PairAttempt(
          totalMatches: totalMatches,
          good: good,
          failStage: 'ransac',
          failReason: 'homography could not be estimated',
        );
      }
      final inliers = inlierMask.countNoneZero;
      final hv = _read3x3(h);
      if (inliers < PanoramaStitcher._minInliers ||
          inliers / good < PanoramaStitcher._minInlierRatio) {
        return _PairAttempt(
          totalMatches: totalMatches,
          good: good,
          inliers: inliers,
          failStage: 'ransac',
          failReason:
              'only $inliers of $good matches are geometrically consistent',
        );
      }
      final why = _degenerate(hv);
      if (why != null) {
        return _PairAttempt(
          totalMatches: totalMatches,
          good: good,
          inliers: inliers,
          failStage: 'homography',
          failReason: why,
        );
      }
      return _PairAttempt(
        totalMatches: totalMatches,
        good: good,
        inliers: inliers,
        homography: hv,
      );
    } finally {
      h.dispose();
    }
  } finally {
    srcMat.dispose();
    dstMat.dispose();
    inlierMask.dispose();
  }
}

/// A pure horizontal shift in cylindrical space: a heading difference is
/// exactly a yaw rotation, and the cylindrical projection already linearises
/// yaw into a horizontal pixel offset scaled by the focal length used for
/// that projection (see [_prepare]). Sign calibrated against real captured
/// images: a positive (clockwise) heading increase from [prevHeadingDeg] to
/// [curHeadingDeg] shifts the current image's content to a smaller
/// cylindrical x in the previous image's frame.
List<double> _compassHomography(
  double f,
  double prevHeadingDeg,
  double curHeadingDeg,
) {
  final deltaDeg = _angleDiffDeg(curHeadingDeg, prevHeadingDeg);
  final tx = -f * deltaDeg * math.pi / 180;
  return <double>[1, 0, tx, 0, 1, 0, 0, 0, 1];
}

/// Shortest signed difference a-b, wrapped to (-180, 180], in degrees.
double _angleDiffDeg(double a, double b) {
  var d = (a - b) % 360;
  if (d <= -180) d += 360;
  if (d > 180) d -= 360;
  return d;
}

/// Load, downscale, cylindrically project and describe one image.
_Frame _prepare(String path, int index, cv.SIFT sift, double? headingDeg) {
  final original = cv.imread(path);
  if (original.isEmpty) {
    throw PanoramaStitchException(
      'load',
      'image $index could not be decoded',
      pair: index,
    );
  }
  final scale = PanoramaStitcher._workingLongSide /
      math.max(original.cols, original.rows);
  final small = scale < 1
      ? cv.resize(original, (
          (original.cols * scale).round(),
          (original.rows * scale).round(),
        ))
      : original.clone();
  original.dispose();

  // Cylindrical projection so a 360° sweep can be chained with homographies.
  final w = small.cols, h = small.rows;
  final f = (w / 2) / math.tan(PanoramaStitcher._assumedHorizontalFov / 2);
  final cx = w / 2, cy = h / 2;
  final outW = (2 * f * math.atan(cx / f)).round();
  final mapX = Float32List(outW * h), mapY = Float32List(outW * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < outW; x++) {
      final theta = (x - outW / 2) / f;
      final hh = (y - cy) / f;
      mapX[y * outW + x] = (f * math.tan(theta) + cx).toDouble();
      mapY[y * outW + x] = (f * hh / math.cos(theta) + cy).toDouble();
    }
  }
  final mx = cv.Mat.fromList(h, outW, cv.MatType.CV_32FC1, mapX);
  final my = cv.Mat.fromList(h, outW, cv.MatType.CV_32FC1, mapY);
  final cyl = cv.remap(small, mx, my, cv.INTER_LINEAR);
  final ones = cv.Mat.fromScalar(h, w, cv.MatType.CV_8UC1, cv.Scalar.all(255));
  final mask = cv.remap(ones, mx, my, cv.INTER_NEAREST);
  for (final mat in [small, mx, my, ones]) {
    mat.dispose();
  }

  final gray = cv.cvtColor(cyl, cv.COLOR_BGR2GRAY);
  final (keypoints, descriptors) = sift.detectAndCompute(gray, mask);
  gray.dispose();
  if (keypoints.length < 50) {
    throw PanoramaStitchException(
      'features',
      'image $index has only ${keypoints.length} SIFT keypoints (too little texture or too blurry)',
      pair: index,
    );
  }
  return _Frame(cyl, mask, keypoints, descriptors, f, headingDeg);
}

const _identity = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];

List<double> _read3x3(cv.Mat m) {
  final data = Float64List.fromList(
    m.data.buffer.asFloat64List(m.data.offsetInBytes, 9),
  );
  return [for (final v in data) v / data[8]];
}

List<double> _mul(List<double> a, List<double> b) => [
  for (var r = 0; r < 3; r++)
    for (var c = 0; c < 3; c++)
      a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c],
];

List<double> _apply(List<double> h, double x, double y) {
  final d = h[6] * x + h[7] * y + h[8];
  return [(h[0] * x + h[1] * y + h[2]) / d, (h[3] * x + h[4] * y + h[5]) / d];
}

/// Rejects homographies that are not a plausible small camera rotation between
/// cylindrically projected frames (huge scale/shear/perspective terms).
String? _degenerate(List<double> h) {
  if (h.any((v) => !v.isFinite)) return 'homography contains non-finite values';
  final det = h[0] * h[4] - h[1] * h[3];
  if (det < 0.5 || det > 2.0) return 'implausible scale change (det=$det)';
  if (h[6].abs() > 0.002 || h[7].abs() > 0.002) {
    return 'excessive perspective distortion';
  }
  if (h[2].abs() < 1) return 'no horizontal displacement between frames';
  return null;
}
