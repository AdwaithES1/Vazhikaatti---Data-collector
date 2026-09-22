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
    required this.usedImageCount,
    required this.droppedImages,
    required this.dropReasons,
    required this.recoveredImages,
    this.loopClosureErrorDeg,
  });
  final String path;
  final int width;
  final int height;
  final int keypointCount;
  final int totalMatches;
  final int goodMatches;
  final int inlierCount;
  /// How many of the input images were actually placed in the panorama.
  final int usedImageCount;
  /// 1-based indices of images that shared no verified overlap - directly,
  /// indirectly, or under a second detector - with the rest, and so were
  /// left out rather than forced into the panorama or failing the whole
  /// stitch.
  final List<int> droppedImages;
  /// For every entry in [droppedImages], the best evidence found for it and
  /// why that fell short - e.g. the strongest candidate match's inlier count
  /// and ratio against the closest other image, and whether an alternate
  /// detector or indirect (triangulated) recovery was attempted.
  final Map<int, String> dropReasons;
  /// 1-based indices of images that did *not* have a direct strong match to
  /// the main group and were instead placed via a second detector or
  /// triangulated agreement between two indirect matches.
  final List<int> recoveredImages;
  /// If the placed images include a pair whose own matched overlap should
  /// close the 360° loop (i.e. an edge connecting the two angular extremes of
  /// the arrangement), the discrepancy in degrees between that edge's own
  /// implied angle and the angle implied by the rest of the chain - a
  /// consistency check on the recovered circular structure. Null when no
  /// such closing edge exists to check against.
  final double? loopClosureErrorDeg;
  double get inlierRatio => goodMatches == 0 ? 0 : inlierCount / goodMatches;
}

/// Stitches an unordered set of images taken around one point into a single
/// 360°-style panorama, purely from image content - no assumption about
/// capture order or any sensor reading:
///
/// cylindrical pre-warp (so a pure rotation becomes a horizontal pixel shift)
/// → SIFT → kNN descriptor matching → Lowe ratio test → RANSAC homography,
/// tried between *every* pair of images in *both* directions → the validated
/// pairs form a graph, from which the largest strongly-connected group is
/// placed by composing homographies along the strongest available path
/// (maximum-spanning tree by inlier count) → any image left over is put
/// through a recovery stage: retried against the placed group with a second,
/// complementary detector (ORB), and - failing that - checked for indirect
/// (triangulated) agreement between two independently weak matches to two
/// different placed images, which is accepted as corroborating evidence
/// without lowering the acceptance bar for any single match → perspective
/// warp → winner-takes-one compositing (the single most reliable source per
/// pixel, not an average) → crop to the largest fully-covered rectangle.
///
/// An image is only left out when none of the above finds it a trustworthy
/// place - see [PanoramaStitchResult.droppedImages] and
/// [PanoramaStitchResult.dropReasons]. The pipeline only fails outright when
/// fewer than 2 images end up connected to each other at all, or a whole
/// image can't be decoded or has essentially no texture.
class PanoramaStitcher {
  static const ratioThreshold = 0.75;
  static const ransacThreshold = 3.0;
  static const descriptorDimension = 128;
  static const _minGoodMatches = 15;
  static const _minInliers = 12;
  static const _minInlierRatio = 0.3;
  // Floor for a match to be considered as recovery evidence at all - well
  // below the acceptance bar above, so a weak candidate is never placed on
  // its own merit alone; it only counts when a second, independent weak
  // candidate to a different image corroborates it (see [_tryTriangulation]).
  static const _weakMinGoodMatches = 6;
  static const _weakMinInliers = 6;
  static const _weakMinInlierRatio = 0.15;
  // Two independent weak candidates must predict the same global angle for
  // the recovered image within this tolerance to be accepted.
  static const _triangulationToleranceDeg = 8.0;
  static const _maxRecoveryPasses = 4;
  static const _orbFeatures = 2000;
  static const _workingLongSide = 1280;
  // Phone cameras are ~60° wide; used only for the cylindrical pre-warp.
  static const _assumedHorizontalFov = 60 * math.pi / 180;

  /// Stitches [imagePaths] - in any order - into one JPEG at [outputPath].
  /// Runs in a background isolate; throws [PanoramaStitchException] if fewer
  /// than 2 images end up connected, or an individual image can't be used.
  static Future<PanoramaStitchResult> stitch(
    List<String> imagePaths,
    String outputPath,
  ) => Isolate.run(() => _stitch(imagePaths, outputPath));
}

class _Frame {
  _Frame(this.image, this.mask, this.keypoints, this.descriptors, this.f);
  final cv.Mat image;
  final cv.Mat mask;
  final cv.VecKeyPoint keypoints;
  final cv.Mat descriptors;
  final double f;
  // Lazily populated only for images that need recovery.
  cv.VecKeyPoint? orbKeypoints;
  cv.Mat? orbDescriptors;
}

/// Result of matching+RANSAC for one pair, before the caller decides whether
/// it is trustworthy enough to use as a strong edge, weak (recovery-only)
/// evidence, or not at all.
class _PairAttempt {
  const _PairAttempt({
    required this.totalMatches,
    required this.good,
    this.homography,
    this.inliers = 0,
  });
  final int totalMatches;
  final int good;
  final List<double>? homography;
  final int inliers;
  bool get isStrong =>
      homography != null &&
      good >= PanoramaStitcher._minGoodMatches &&
      inliers >= PanoramaStitcher._minInliers &&
      inliers / good >= PanoramaStitcher._minInlierRatio;
  bool get isWeak =>
      homography != null &&
      good >= PanoramaStitcher._weakMinGoodMatches &&
      inliers >= PanoramaStitcher._weakMinInliers &&
      inliers / good >= PanoramaStitcher._weakMinInlierRatio;
}

/// A validated link between two images: [hHigherToLower] maps [higher]'s
/// cylindrical coordinates into [lower]'s ([higher] > [lower]).
class _Edge {
  const _Edge(this.lower, this.higher, this.hHigherToLower, this.good, this.inliers);
  final int lower;
  final int higher;
  final List<double> hHigherToLower;
  final int good;
  final int inliers;
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
      f.orbKeypoints?.dispose();
      f.orbDescriptors?.dispose();
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
  final n = frames.length;

  // Try every pair - with no assumed order, "adjacent" means nothing; the
  // true arrangement can only come from checking all of them. Each pair is
  // checked in both directions and classified by the *weaker* of the two
  // results, so the outcome never depends on which image happened to be
  // passed first: a pair only counts as strong evidence when both
  // directions independently clear the strong bar, and as weak (recovery)
  // evidence when both clear the much lower weak floor.
  final strongEdges = <_Edge>[];
  final weakEdges = <_Edge>[];
  var totalMatches = 0;
  for (var lower = 0; lower < n; lower++) {
    for (var higher = lower + 1; higher < n; higher++) {
      final forward = _matchAndValidate(
        frames[higher].keypoints, frames[higher].descriptors,
        frames[lower].keypoints, frames[lower].descriptors,
        matcher,
      );
      final backward = _matchAndValidate(
        frames[lower].keypoints, frames[lower].descriptors,
        frames[higher].keypoints, frames[higher].descriptors,
        matcher,
      );
      totalMatches += forward.totalMatches + backward.totalMatches;
      if (forward.homography == null || backward.homography == null) continue;
      // Use whichever direction found more inliers, but only after both have
      // already independently cleared the same bar.
      final useForward = forward.inliers >= backward.inliers;
      final edge = useForward
          ? _Edge(lower, higher, forward.homography!, forward.good, forward.inliers)
          : _Edge(lower, higher, _invert3x3(backward.homography!), backward.good, backward.inliers);
      if (forward.isStrong && backward.isStrong) {
        strongEdges.add(edge);
      } else if (forward.isWeak && backward.isWeak) {
        weakEdges.add(edge);
      }
    }
  }

  // Build a maximum-spanning forest (by inlier count) over *every* strong
  // edge, not just ones touching the eventual largest group - so that if two
  // images (say A and B) are strongly linked to each other but not to the
  // main group, and recovery later bridges just A into it, B becomes
  // reachable through the A-B edge already sitting in this forest, with no
  // separate recovery needed for B.
  strongEdges.sort((a, b) => b.inliers.compareTo(a.inliers));
  final treeOf = List<int>.generate(n, (i) => i);
  int findTree(int i) => treeOf[i] == i ? i : treeOf[i] = findTree(treeOf[i]);
  final adjacency = List.generate(n, (_) => <_Edge>[]);
  final componentSize = <int, int>{for (var i = 0; i < n; i++) i: 1};
  for (final edge in strongEdges) {
    final a = findTree(edge.lower), b = findTree(edge.higher);
    if (a != b) {
      treeOf[a] = b;
      componentSize[b] = (componentSize[a] ?? 1) + (componentSize[b] ?? 1);
      componentSize.remove(a);
      adjacency[edge.lower].add(edge);
      adjacency[edge.higher].add(edge);
    }
  }
  final mainRoot = componentSize.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  final core = {for (var i = 0; i < n; i++) if (findTree(i) == mainRoot) i};
  if (core.length < 2) {
    throw const PanoramaStitchException(
      'matching',
      'no two images share enough verified overlap to build a panorama',
    );
  }

  final global = List<List<double>?>.filled(n, null);
  var goodMatches = 0, inlierCount = 0;
  final reference = (core.toList()..sort()).first;
  final f = frames[reference].f;
  global[reference] = _identity;
  void expand(int start) {
    final queue = <int>[start];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final edge in adjacency[current]) {
        final other = edge.lower == current ? edge.higher : edge.lower;
        if (global[other] != null) continue;
        final hOtherToCurrent = other == edge.higher
            ? edge.hHigherToLower
            : _invert3x3(edge.hHigherToLower);
        global[other] = _mul(global[current]!, hOtherToCurrent);
        goodMatches += edge.good;
        inlierCount += edge.inliers;
        queue.add(other);
      }
    }
  }

  expand(reference);

  // Recovery: anything not in the core is retried, first with a second
  // detector against every placed image (same acceptance bar as SIFT, just a
  // different feature type that may catch texture SIFT missed), then by
  // checking whether two independently weak matches to two different placed
  // images agree on where the image belongs - agreement between two
  // unrelated weak signals is real corroborating evidence, so this recovers
  // a genuine connection without ever lowering what counts as "connected".
  // Recovering one image can newly enable triangulation for another, so this
  // repeats until a full pass makes no further progress.
  cv.ORB? orb;
  cv.BFMatcher? orbMatcher;
  final recovered = <int>[];
  final bestEvidence = <int, String>{};
  var pass = 0;
  var unplaced = [for (var i = 0; i < n; i++) if (global[i] == null) i];
  while (unplaced.isNotEmpty && pass < PanoramaStitcher._maxRecoveryPasses) {
    pass++;
    var progressed = false;
    for (final d in unplaced) {
      if (global[d] != null) continue; // placed earlier this pass via triangulation
      final placedNow = [for (var i = 0; i < n; i++) if (global[i] != null) i];

      // Second detector: same strong bar, different feature type.
      orb ??= cv.ORB.create(nFeatures: PanoramaStitcher._orbFeatures);
      orbMatcher ??= cv.BFMatcher.create(type: cv.NORM_HAMMING);
      _ensureOrb(frames[d], orb);
      _Edge? orbEdge;
      for (final c in placedNow) {
        _ensureOrb(frames[c], orb);
        final fwd = _matchAndValidate(
          frames[d].orbKeypoints!, frames[d].orbDescriptors!,
          frames[c].orbKeypoints!, frames[c].orbDescriptors!,
          orbMatcher,
        );
        final bwd = _matchAndValidate(
          frames[c].orbKeypoints!, frames[c].orbDescriptors!,
          frames[d].orbKeypoints!, frames[d].orbDescriptors!,
          orbMatcher,
        );
        if (fwd.isStrong && bwd.isStrong && fwd.homography != null && bwd.homography != null) {
          final edge = fwd.inliers >= bwd.inliers
              ? _Edge(math.min(d, c), math.max(d, c),
                  d < c ? _invert3x3(fwd.homography!) : fwd.homography!, fwd.good, fwd.inliers)
              : _Edge(math.min(d, c), math.max(d, c),
                  d < c ? bwd.homography! : _invert3x3(bwd.homography!), bwd.good, bwd.inliers);
          if (orbEdge == null || edge.inliers > orbEdge.inliers) orbEdge = edge;
        }
      }
      if (orbEdge != null) {
        final other = orbEdge.lower == d ? orbEdge.higher : orbEdge.lower;
        final hOtherToD = other == orbEdge.higher ? orbEdge.hHigherToLower : _invert3x3(orbEdge.hHigherToLower);
        // hOtherToD maps `other` -> d; we need d -> other, i.e. its inverse,
        // composed onto other's known global position.
        global[d] = _mul(global[other]!, _invert3x3(hOtherToD));
        adjacency[d].add(orbEdge);
        adjacency[other].add(orbEdge);
        goodMatches += orbEdge.good;
        inlierCount += orbEdge.inliers;
        recovered.add(d + 1);
        progressed = true;
        expand(d);
        continue;
      }

      // Indirect triangulation: gather weak candidates from d to every
      // currently-placed image - SIFT ones from the already bidirectionally-
      // validated weakEdges computed up front, plus ORB ones checked the
      // same bidirectional way here. Requiring both directions to
      // independently agree, even at this much lower bar, catches pairs
      // whose apparent match hides a real geometric inconsistency (e.g. the
      // reverse direction implying an implausible scale change that the
      // forward direction alone wouldn't reveal).
      final candidates = <(int other, List<double> hDToOther, int good, int inliers)>[];
      for (final edge in weakEdges) {
        if (edge.lower != d && edge.higher != d) continue;
        final other = edge.lower == d ? edge.higher : edge.lower;
        if (!placedNow.contains(other)) continue;
        final hDToOther = edge.higher == d ? edge.hHigherToLower : _invert3x3(edge.hHigherToLower);
        candidates.add((other, hDToOther, edge.good, edge.inliers));
      }
      for (final c in placedNow) {
        if (frames[d].orbDescriptors == null || frames[c].orbDescriptors == null) continue;
        final fwd = _matchAndValidate(
          frames[d].orbKeypoints!, frames[d].orbDescriptors!,
          frames[c].orbKeypoints!, frames[c].orbDescriptors!,
          orbMatcher,
        );
        final bwd = _matchAndValidate(
          frames[c].orbKeypoints!, frames[c].orbDescriptors!,
          frames[d].orbKeypoints!, frames[d].orbDescriptors!,
          orbMatcher,
        );
        if (fwd.isWeak && bwd.isWeak && fwd.homography != null && bwd.homography != null) {
          final useFwd = fwd.inliers >= bwd.inliers;
          candidates.add((
            c,
            useFwd ? fwd.homography! : _invert3x3(bwd.homography!),
            useFwd ? fwd.good : bwd.good,
            useFwd ? fwd.inliers : bwd.inliers,
          ));
        }
      }

      _Edge? accepted;
      var bestDisagreement = double.infinity;
      for (var i = 0; i < candidates.length; i++) {
        for (var j = i + 1; j < candidates.length; j++) {
          final (c1, hDTo1, good1, inliers1) = candidates[i];
          final (c2, hDTo2, good2, inliers2) = candidates[j];
          if (c1 == c2) continue;
          final angle1 = _effectiveAngleDeg(_mul(global[c1]!, hDTo1), f);
          final angle2 = _effectiveAngleDeg(_mul(global[c2]!, hDTo2), f);
          final disagreement = _angleDiffDeg(angle1, angle2).abs();
          if (disagreement < bestDisagreement) bestDisagreement = disagreement;
          if (disagreement <= PanoramaStitcher._triangulationToleranceDeg) {
            final better = inliers1 >= inliers2
                ? _Edge(math.min(d, c1), math.max(d, c1),
                    d < c1 ? _invert3x3(hDTo1) : hDTo1, good1, inliers1)
                : _Edge(math.min(d, c2), math.max(d, c2),
                    d < c2 ? _invert3x3(hDTo2) : hDTo2, good2, inliers2);
            if (accepted == null || better.inliers > accepted.inliers) accepted = better;
          }
        }
      }
      if (accepted != null) {
        final other = accepted.lower == d ? accepted.higher : accepted.lower;
        final hOtherToD = other == accepted.higher ? accepted.hHigherToLower : _invert3x3(accepted.hHigherToLower);
        global[d] = _mul(global[other]!, _invert3x3(hOtherToD));
        adjacency[d].add(accepted);
        adjacency[other].add(accepted);
        goodMatches += accepted.good;
        inlierCount += accepted.inliers;
        recovered.add(d + 1);
        progressed = true;
        expand(d);
        continue;
      }

      // Nothing worked this pass; keep the best evidence seen for reporting.
      final best = [...candidates]..sort((a, b) => b.$4.compareTo(a.$4));
      if (best.isNotEmpty) {
        final (c, _, good, inliers) = best.first;
        final ratioPct = good == 0 ? 0 : (inliers / good * 100).round();
        bestEvidence[d + 1] =
            'best candidate match: $inliers inliers of $good good matches '
            '($ratioPct% inlier ratio) against image ${c + 1}, short of the '
            '${PanoramaStitcher._minInliers} inliers / '
            '${(PanoramaStitcher._minInlierRatio * 100).round()}% ratio required; '
            'no second independent match agreed closely enough '
            '(closest disagreement '
            '${bestDisagreement.isFinite ? '${bestDisagreement.toStringAsFixed(1)}°' : 'n/a'} '
            'vs the ${PanoramaStitcher._triangulationToleranceDeg.toStringAsFixed(0)}° tolerance) '
            'to corroborate it';
      } else {
        bestEvidence[d + 1] =
            'no candidate match (even a weak one) was found against any other image, '
            'with either SIFT or ORB features';
      }
    }
    unplaced = [for (var i = 0; i < n; i++) if (global[i] == null) i];
    if (!progressed) break;
  }
  orb?.dispose();
  orbMatcher?.dispose();

  final placed = [for (var i = 0; i < n; i++) if (global[i] != null) i]..sort();
  final dropped = [for (var i = 0; i < n; i++) if (global[i] == null) i + 1];
  final dropReasons = {for (final d in dropped) d: bestEvidence[d] ?? 'no evidence found'};

  // Loop-closure diagnostic: if the two angular extremes of the placed set
  // are themselves linked by a candidate edge that wasn't used for
  // placement, check how well it agrees with the rest of the chain.
  double? loopClosureErrorDeg;
  if (placed.length >= 3) {
    final anglesByImage = {for (final i in placed) i: _effectiveAngleDeg(global[i]!, f)};
    final sortedByAngle = placed.toList()..sort((a, b) => anglesByImage[a]!.compareTo(anglesByImage[b]!));
    final lo = sortedByAngle.first, hi = sortedByAngle.last;
    final closing = [...strongEdges, ...weakEdges].where(
      (e) => (e.lower == lo && e.higher == hi) || (e.lower == hi && e.higher == lo),
    ).toList()
      ..sort((a, b) => b.inliers.compareTo(a.inliers));
    if (closing.isNotEmpty) {
      final edge = closing.first;
      // hHiToLo maps hi's coords -> lo's coords, directly or inverted
      // depending on which of hi/lo the edge stored as its "higher" index.
      final hHiToLo = edge.higher == hi ? edge.hHigherToLower : _invert3x3(edge.hHigherToLower);
      final chainDelta = _angleDiffDeg(anglesByImage[hi]!, anglesByImage[lo]!);
      final edgeDelta = _angleDiffDeg(
        _effectiveAngleDeg(_mul(global[lo]!, hHiToLo), f),
        anglesByImage[lo]!,
      );
      loopClosureErrorDeg = _angleDiffDeg(chainDelta, edgeDelta).abs();
    }
  }

  // Canvas bounds from the warped image corners.
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final i in placed) {
    final w = frames[i].image.cols.toDouble(), h = frames[i].image.rows;
    for (final c in [
      [0.0, 0.0],
      [w, 0.0],
      [w, h.toDouble()],
      [0.0, h.toDouble()],
    ]) {
      final p = _apply(global[i]!, c[0], c[1]);
      minX = math.min(minX, p[0]);
      maxX = math.max(maxX, p[0]);
      minY = math.min(minY, p[1]);
      maxY = math.max(maxY, p[1]);
    }
  }
  final canvasWidth = (maxX - minX).ceil(), canvasHeight = (maxY - minY).ceil();
  if (!minX.isFinite ||
      !minY.isFinite ||
      canvasWidth < frames[reference].image.cols ||
      canvasWidth > 16000 ||
      canvasHeight < 1 ||
      canvasHeight > 4000) {
    throw PanoramaStitchException(
      'warp',
      'implausible panorama canvas ${canvasWidth}x$canvasHeight',
    );
  }
  final shift = <double>[1, 0, -minX, 0, 1, -minY, 0, 0, 1];

  // Winner-takes-one compositing: at each pixel, keep the single source image
  // whose distance transform (distance to its own border) is largest there,
  // rather than averaging every overlapping image together. Two images that
  // validly overlap can still end up covering nearly the same area (e.g. if
  // the true angular gap between them turns out much smaller than their
  // position in the sequence suggested); averaging every contributor there
  // produces a transparent double-exposure ghost instead of a clean wall, so
  // the seam is resolved by ownership per pixel instead of blending across it.
  var bestWeight = cv.Mat.zeros(canvasHeight, canvasWidth, cv.MatType.CV_32FC1);
  var bestColor = cv.Mat.zeros(canvasHeight, canvasWidth, cv.MatType.CV_8UC3);
  // Tracks which image currently owns each pixel (255 = none yet), so stray
  // fragments from an unrelated placement can be found and removed below.
  var ownerIndex = cv.Mat.fromScalar(canvasHeight, canvasWidth, cv.MatType.CV_8UC1, cv.Scalar.all(255));
  // warpPerspective's bilinear sampling blends real content with the black
  // implicit border right at each image's edge; feather blending used to
  // dilute that into other contributors, but winner-takes-one would display
  // it raw, so the mask is eroded first to keep that fringe out of
  // contention entirely.
  final erosionKernel = cv.Mat.ones(11, 11, cv.MatType.CV_8UC1);
  for (final i in placed) {
    final m = cv.Mat.fromList(3, 3, cv.MatType.CV_64FC1, _mul(shift, global[i]!));
    final warped = cv.warpPerspective(frames[i].image, m, (canvasWidth, canvasHeight));
    final warpedMaskRaw = cv.warpPerspective(
      frames[i].mask,
      m,
      (canvasWidth, canvasHeight),
      flags: cv.INTER_NEAREST,
    );
    final warpedMask = cv.erode(warpedMaskRaw, erosionKernel);
    final (dist, labels) = cv.distanceTransform(
      warpedMask,
      cv.DIST_L2,
      3,
      cv.DIST_LABEL_CCOMP,
    );
    final dist32 = dist.type == cv.MatType.CV_32FC1
        ? dist
        : dist.convertTo(cv.MatType.CV_32FC1);
    final better = cv.compare(dist32, bestWeight, cv.CMP_GT);
    final idxMat = cv.Mat.fromScalar(canvasHeight, canvasWidth, cv.MatType.CV_8UC1, cv.Scalar.all(i.toDouble()));
    warped.copyTo(bestColor, mask: better);
    dist32.copyTo(bestWeight, mask: better);
    idxMat.copyTo(ownerIndex, mask: better);
    for (final mat in [m, warped, warpedMaskRaw, warpedMask, dist, labels, better, idxMat]) {
      mat.dispose();
    }
    if (!identical(dist32, dist)) dist32.dispose();
  }
  erosionKernel.dispose();

  // Two images can be placed via completely different paths through the
  // evidence graph and still end up spatially overlapping on the canvas even
  // though they show unrelated parts of the space - nothing about a 2D
  // layout stops that. Where it happens, winner-takes-one can let a small,
  // spatially isolated sliver of the "wrong" image through wherever it's
  // locally closer to its own border. Keeping only each image's single
  // largest connected placement removes that; the pixels it drops become
  // uncovered, so the crop below naturally steers around them.
  final ownerBytes = ownerIndex.data;
  final weightBytes = bestWeight.data;
  final weightFloats = weightBytes.buffer.asFloat32List(weightBytes.offsetInBytes, canvasWidth * canvasHeight);
  _keepOnlyLargestBlobPerOwner(ownerBytes, weightFloats, canvasWidth, canvasHeight);
  ownerIndex.dispose();

  // Crop to the largest rectangle that every source image actually covers,
  // instead of shipping the scalloped/black-cornered raw canvas.
  final coverage = _coverageMask(bestWeight, canvasWidth, canvasHeight);
  final crop = _largestCoveredRect(coverage, canvasWidth, canvasHeight);
  if (crop.width < frames[reference].image.cols ~/ 2 || crop.height < 10) {
    for (final mat in [bestWeight, bestColor]) {
      mat.dispose();
    }
    throw const PanoramaStitchException(
      'warp',
      'no rectangle of the panorama is covered by enough images to crop cleanly',
    );
  }
  final result = cv.Mat.fromMat(
    bestColor,
    roi: cv.Rect(crop.left, crop.top, crop.width, crop.height),
    copy: true,
  );
  final width = result.cols, height = result.rows;

  cv.imwrite(
    outputPath,
    result,
    params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 92]),
  );
  for (final mat in [bestWeight, bestColor, result]) {
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
    usedImageCount: placed.length,
    droppedImages: dropped,
    dropReasons: dropReasons,
    recoveredImages: recovered,
    loopClosureErrorDeg: loopClosureErrorDeg,
  );
}

/// Computes ORB keypoints/descriptors for [frame] if not already cached.
void _ensureOrb(_Frame frame, cv.ORB orb) {
  if (frame.orbDescriptors != null) return;
  final gray = cv.cvtColor(frame.image, cv.COLOR_BGR2GRAY);
  final (kp, desc) = orb.detectAndCompute(gray, frame.mask);
  gray.dispose();
  frame.orbKeypoints = kp;
  frame.orbDescriptors = desc;
}

/// Runs kNN matching + the Lowe ratio test + RANSAC homography estimation for
/// one pair, returning a validated homography if one exists - never throws,
/// so the caller can just skip an unvalidated pair rather than abort. Works
/// for any detector's keypoints/descriptors (SIFT or ORB), matched with a
/// distance-appropriate matcher (L2 or Hamming respectively).
_PairAttempt _matchAndValidate(
  cv.VecKeyPoint curKp,
  cv.Mat curDesc,
  cv.VecKeyPoint prevKp,
  cv.Mat prevDesc,
  cv.BFMatcher matcher,
) {
  final knn = matcher.knnMatch(curDesc, prevDesc, 2);
  var totalMatches = 0;
  final src = <double>[], dst = <double>[];
  try {
    for (var m = 0; m < knn.length; m++) {
      final pairMatches = knn[m];
      if (pairMatches.length < 2) continue;
      totalMatches++;
      if (pairMatches[0].distance <
          PanoramaStitcher.ratioThreshold * pairMatches[1].distance) {
        final a = curKp[pairMatches[0].queryIdx];
        final b = prevKp[pairMatches[0].trainIdx];
        src..add(a.x)..add(a.y);
        dst..add(b.x)..add(b.y);
      }
    }
  } finally {
    knn.dispose();
  }
  final good = src.length ~/ 2;
  if (good < PanoramaStitcher._weakMinGoodMatches) {
    return _PairAttempt(totalMatches: totalMatches, good: good);
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
        return _PairAttempt(totalMatches: totalMatches, good: good);
      }
      final inliers = inlierMask.countNoneZero;
      final hv = _read3x3(h);
      if (_degenerate(hv) != null) {
        return _PairAttempt(totalMatches: totalMatches, good: good, inliers: inliers);
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

  // Cylindrical projection: a pure rotation of the camera becomes a plain
  // horizontal pixel shift in this space, which is what lets homographies
  // between images be chained around a full circle at all.
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
  return _Frame(cyl, mask, keypoints, descriptors, f);
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

/// Inverse of a 3x3 matrix via the adjugate, needed to walk a validated edge
/// backwards (higher-to-lower is what matching produces; the spanning-tree
/// walk sometimes needs lower-to-higher).
List<double> _invert3x3(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final invDet = 1 / det;
  return <double>[
    (e * i - f * h) * invDet,
    (c * h - b * i) * invDet,
    (b * f - c * e) * invDet,
    (f * g - d * i) * invDet,
    (a * i - c * g) * invDet,
    (c * d - a * f) * invDet,
    (d * h - e * g) * invDet,
    (b * g - a * h) * invDet,
    (a * e - b * d) * invDet,
  ];
}

List<double> _apply(List<double> h, double x, double y) {
  final d = h[6] * x + h[7] * y + h[8];
  return [(h[0] * x + h[1] * y + h[2]) / d, (h[3] * x + h[4] * y + h[5]) / d];
}

/// The effective horizontal-shift angle (degrees) a global placement matrix
/// represents, normalising by its own homogeneous scale first since matrix
/// composition/inversion does not keep that entry at 1. Used only for the
/// triangulation and loop-closure consistency checks, not for the warp
/// itself, which uses the full matrix.
double _effectiveAngleDeg(List<double> g, double f) => -(g[2] / g[8]) / f * 180 / math.pi;

/// Shortest signed difference a-b, wrapped to (-180, 180], in degrees.
double _angleDiffDeg(double a, double b) {
  var d = (a - b) % 360;
  if (d <= -180) d += 360;
  if (d > 180) d -= 360;
  return d;
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

/// For every image index present in [owner] (0-254; 255 means unowned),
/// finds its largest 4-connected blob of pixels and zeroes [weight] (a flat
/// view over the blend accumulator, mutated in place) everywhere that same
/// image owns a *different*, smaller blob - a spatially isolated fragment
/// from two independently-placed, topologically-unrelated images happening
/// to overlap on the canvas.
void _keepOnlyLargestBlobPerOwner(
  Uint8List owner,
  Float32List weight,
  int width,
  int height,
) {
  final total = width * height;
  final blobId = Int32List(total)..fillRange(0, total, -1);
  final blobSize = <int>[];
  final blobOwner = <int>[];
  for (var start = 0; start < total; start++) {
    if (blobId[start] != -1 || owner[start] == 255) continue;
    final ownerVal = owner[start];
    final id = blobSize.length;
    blobId[start] = id;
    final queue = <int>[start];
    var head = 0;
    while (head < queue.length) {
      final idx = queue[head++];
      final x = idx % width, y = idx ~/ width;
      if (x > 0 && blobId[idx - 1] == -1 && owner[idx - 1] == ownerVal) {
        blobId[idx - 1] = id;
        queue.add(idx - 1);
      }
      if (x < width - 1 && blobId[idx + 1] == -1 && owner[idx + 1] == ownerVal) {
        blobId[idx + 1] = id;
        queue.add(idx + 1);
      }
      if (y > 0 && blobId[idx - width] == -1 && owner[idx - width] == ownerVal) {
        blobId[idx - width] = id;
        queue.add(idx - width);
      }
      if (y < height - 1 && blobId[idx + width] == -1 && owner[idx + width] == ownerVal) {
        blobId[idx + width] = id;
        queue.add(idx + width);
      }
    }
    blobSize.add(queue.length);
    blobOwner.add(ownerVal);
  }
  final largestBlobForOwner = <int, int>{};
  for (var id = 0; id < blobSize.length; id++) {
    final o = blobOwner[id];
    final currentLargest = largestBlobForOwner[o];
    if (currentLargest == null || blobSize[id] > blobSize[currentLargest]) {
      largestBlobForOwner[o] = id;
    }
  }
  for (var idx = 0; idx < total; idx++) {
    final id = blobId[idx];
    if (id != -1 && id != largestBlobForOwner[blobOwner[id]]) {
      weight[idx] = 0;
    }
  }
}

/// 0/1 per-pixel coverage (any image contributed a non-zero blend weight),
/// read directly out of the blend accumulator to avoid a further OpenCV pass.
Uint8List _coverageMask(cv.Mat weights, int width, int height) {
  final bytes = weights.data;
  final floats = bytes.buffer.asFloat32List(bytes.offsetInBytes, width * height);
  final mask = Uint8List(width * height);
  for (var i = 0; i < mask.length; i++) {
    mask[i] = floats[i] > 0 ? 1 : 0;
  }
  return mask;
}

/// Largest all-covered axis-aligned rectangle within a row-major binary mask,
/// via the standard histogram/monotonic-stack "maximal rectangle" algorithm.
({int left, int top, int width, int height}) _largestCoveredRect(
  Uint8List mask,
  int width,
  int height,
) {
  final heights = List<int>.filled(width, 0);
  var best = (left: 0, top: 0, width: 0, height: 0);
  var bestArea = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      heights[x] = mask[y * width + x] != 0 ? heights[x] + 1 : 0;
    }
    final stack = <int>[];
    for (var x = 0; x <= width; x++) {
      final h = x == width ? 0 : heights[x];
      while (stack.isNotEmpty && heights[stack.last] >= h) {
        final top = stack.removeLast();
        final barHeight = heights[top];
        final left = stack.isEmpty ? 0 : stack.last + 1;
        final rectWidth = x - left;
        final area = barHeight * rectWidth;
        if (area > bestArea) {
          bestArea = area;
          best = (left: left, top: y - barHeight + 1, width: rectWidth, height: barHeight);
        }
      }
      stack.add(x);
    }
  }
  return best;
}
