import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Raised when a stage of the stitching pipeline cannot produce a trustworthy
/// result. For the single-image stages (`load`, `features`), [pair] is the
/// 1-based index of the failing image itself. For every other stage it is the
/// 1-based index of the image pair (image `pair` and `pair + 1`).
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
  });
  final String path;
  final int width;
  final int height;
  final int keypointCount;
  final int totalMatches;
  final int goodMatches;
  final int inlierCount;
  double get inlierRatio => goodMatches == 0 ? 0 : inlierCount / goodMatches;
}

/// Classical panorama stitching:
/// cylindrical pre-warp → SIFT → kNN descriptor matching → Lowe ratio test →
/// RANSAC homography per neighbouring pair → chained perspective warp →
/// distance-weighted (feather) blending.
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
  /// [outputPath]. Runs in a background isolate; throws
  /// [PanoramaStitchException] on any failure.
  static Future<PanoramaStitchResult> stitch(
    List<String> imagePaths,
    String outputPath,
  ) => Isolate.run(() => _stitch(imagePaths, outputPath));
}

class _Frame {
  _Frame(this.image, this.mask, this.keypoints, this.descriptors);
  final cv.Mat image;
  final cv.Mat mask;
  final cv.VecKeyPoint keypoints;
  final cv.Mat descriptors;
}

PanoramaStitchResult _stitch(List<String> paths, String outputPath) {
  if (paths.length < 2) {
    throw const PanoramaStitchException('input', 'At least 2 images required');
  }
  final sift = cv.SIFT.create(nfeatures: 4000);
  final matcher = cv.BFMatcher.create(type: cv.NORM_L2);
  final frames = <_Frame>[];
  try {
    return _stitchFrames(paths, outputPath, sift, matcher, frames);
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
  cv.SIFT sift,
  cv.BFMatcher matcher,
  List<_Frame> frames,
) {
  var keypointCount = 0;
  for (var i = 0; i < paths.length; i++) {
    final frame = _prepare(paths[i], i + 1, sift);
    keypointCount += frame.keypoints.length;
    frames.add(frame);
  }

  // Homography of each image into the previous image's frame, chained to
  // image 0.
  final global = <List<double>>[_identity];
  var totalMatches = 0, goodMatches = 0, inlierCount = 0;
  for (var i = 1; i < frames.length; i++) {
    final pair = i; // images i and i+1 (1-based)
    final knn = matcher.knnMatch(
      frames[i].descriptors,
      frames[i - 1].descriptors,
      2,
    );
    final src = <double>[], dst = <double>[];
    var good = 0;
    try {
      for (var m = 0; m < knn.length; m++) {
        final pairMatches = knn[m];
        if (pairMatches.length < 2) continue;
        totalMatches++;
        if (pairMatches[0].distance <
            PanoramaStitcher.ratioThreshold * pairMatches[1].distance) {
          final a = frames[i].keypoints[pairMatches[0].queryIdx];
          final b = frames[i - 1].keypoints[pairMatches[0].trainIdx];
          src..add(a.x)..add(a.y);
          dst..add(b.x)..add(b.y);
          good++;
        }
      }
    } finally {
      knn.dispose();
    }
    if (good < PanoramaStitcher._minGoodMatches) {
      throw PanoramaStitchException(
        'matching',
        'only $good matches survived the ratio test '
            '(need ${PanoramaStitcher._minGoodMatches}); not enough overlap',
        pair: pair,
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
          throw PanoramaStitchException(
            'ransac',
            'homography could not be estimated',
            pair: pair,
          );
        }
        final inliers = inlierMask.countNoneZero;
        final hv = _read3x3(h);
        if (inliers < PanoramaStitcher._minInliers ||
            inliers / good < PanoramaStitcher._minInlierRatio) {
          throw PanoramaStitchException(
            'ransac',
            'only $inliers of $good matches are geometrically consistent',
            pair: pair,
          );
        }
        final why = _degenerate(hv);
        if (why != null) {
          throw PanoramaStitchException('homography', why, pair: pair);
        }
        goodMatches += good;
        inlierCount += inliers;
        global.add(_mul(global[i - 1], hv));
      } finally {
        h.dispose();
      }
    } finally {
      srcMat.dispose();
      dstMat.dispose();
      inlierMask.dispose();
    }
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
  );
}

/// Load, downscale, cylindrically project and describe one image.
_Frame _prepare(String path, int index, cv.SIFT sift) {
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
  return _Frame(cyl, mask, keypoints, descriptors);
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
