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
    required this.recoveredViaGeometricSearch,
    required this.yawSearchDiagnostics,
    required this.pairDiagnostics,
    this.loopClosureErrorDeg,
    this.sensorPlacedLinks = const [],
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
  /// and ratio against the closest other image, and whether indirect
  /// (triangulated) recovery was attempted.
  final Map<int, String> dropReasons;
  /// 1-based indices of images that had no direct strong (mutually
  /// corroborated) match to the main group and were instead placed via
  /// triangulated agreement between two indirect matches.
  final List<int> recoveredImages;
  /// 1-based indices of images that had no usable direct or triangulated
  /// feature evidence at all, and were instead placed by searching for their
  /// yaw directly against the panorama already built from the reliably
  /// placed images - matching photometric/geometric structure (correlation,
  /// phase correlation, edge structure, block-matching flow consistency)
  /// rather than a feature correspondence. See [yawSearchDiagnostics] for
  /// the full candidate search each of these went through.
  final List<int> recoveredViaGeometricSearch;
  /// For every image that went through the geometric yaw-search stage
  /// (whether or not it was ultimately placed - see
  /// [recoveredViaGeometricSearch] and [droppedImages]), the top scored
  /// candidate yaws considered: each line reports the candidate angle, its
  /// overlap with the existing panorama, feature inliers found against the
  /// nearest anchors, the photometric/phase-correlation/edge/flow-consistency
  /// scores, the combined score, and which placed images it was scored
  /// against.
  final Map<int, List<String>> yawSearchDiagnostics;
  /// One line per accepted link, in placement order: which two images (1-based),
  /// how many inliers/good matches backed it, and whether it was corroborated
  /// by an independent detector/direction (mutual matching) or only reached
  /// through triangulation. A basic version of the diagnostics requirement -
  /// selected order, pairwise inliers, and how each image was justified.
  final List<String> pairDiagnostics;
  /// If the placed images include a pair whose own matched overlap should
  /// close the 360° loop (i.e. an edge connecting the two angular extremes of
  /// the arrangement), the discrepancy in degrees between that edge's own
  /// implied angle and the angle implied by the rest of the chain - a
  /// consistency check on the recovered circular structure. Null when no
  /// such closing edge exists to check against.
  final double? loopClosureErrorDeg;
  /// In-order stitching only: 1-based link numbers (link `k` joins image `k`
  /// to image `k + 1`; link `n` is the closing link from the last image back
  /// to the first) that had no usable visual overlap and were placed from the
  /// compass heading difference, or the expected step, instead.
  final List<int> sensorPlacedLinks;
  double get inlierRatio => goodMatches == 0 ? 0 : inlierCount / goodMatches;
}

/// Stitches an unordered set of images taken around one point into a single
/// 360°-style panorama, purely from image content - no assumption about
/// capture order or any sensor reading:
///
/// cylindrical pre-warp (so a pure rotation becomes a horizontal pixel shift,
/// matching a panoramic-rotation camera model rather than treating each pair
/// as an arbitrary planar homography) → for every pair of images, in both
/// matching directions, with two complementary detectors (SIFT and ORB) →
/// Lowe ratio test → USAC-MAGSAC homography estimation, geometrically
/// validated (rejecting implausible scale/perspective) → a pair counts as
/// solid evidence only when at least two of these independent estimates
/// (different detector and/or direction) agree closely on the same geometry
/// - mutual matching as the actual gate against false correspondences,
/// rather than trusting any single fit alone → the resulting graph's largest
/// mutually-corroborated group is placed by composing homographies along its
/// strongest paths (maximum-spanning tree by inlier count) → any image left
/// over goes through indirect recovery: if two independently weak matches to
/// two different placed images agree on where it belongs, that agreement is
/// accepted as real evidence without ever lowering the bar for a single
/// match → anything *still* unplaced (no usable feature evidence at all)
/// goes through one more, stronger attempt: its cylindrical projection is
/// searched over every possible yaw against the panorama already built from
/// the reliably placed images, scored with several independent
/// photometric/geometric signals (correlation, phase correlation, edge
/// structure, block-matching flow consistency, plus SIFT/ORB/AKAZE evidence
/// for that specific position) and accepted only when at least two of those
/// signals individually clear their own bar and the combined score clears a
/// higher bar still - the same mutual-corroboration philosophy as the
/// feature stage, just without requiring the correspondence to have been a
/// feature match; the two angular extremes of the final arrangement are
/// then checked the same way for a closing, 360°-loop edge → perspective
/// warp → winner-takes-one compositing (the single most reliable source per
/// pixel, not an average, since two images can validly end up covering
/// nearly the same area) → crop to the largest fully-covered rectangle.
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
  // Floor for an estimate to be considered evidence at all - well below the
  // acceptance bar above, so a weak candidate is never placed on its own
  // merit; it only counts when a second, independent estimate corroborates
  // it (see [_classifyPair] for same-pair cross-detector agreement, and
  // triangulation in [_stitchFrames] for cross-image agreement).
  static const _weakMinGoodMatches = 6;
  static const _weakMinInliers = 6;
  static const _weakMinInlierRatio = 0.15;
  // Two independent estimates for the same pair must agree on the implied
  // pixel shift within max(this, this-relative-fraction * magnitude) to
  // count as corroborating each other - a fixed floor plus a fraction of the
  // shift's own size, since a bigger implied rotation naturally carries more
  // absolute pixel-position noise between independent fits.
  static const _agreementTolerancePx = 40.0;
  static const _agreementToleranceFraction = 0.12;
  // Two independent weak candidates (to two different images) must predict
  // the same global angle for the recovered image within this tolerance.
  static const _triangulationToleranceDeg = 8.0;
  static const _maxRecoveryPasses = 4;
  static const _orbFeatures = 3000;
  static const _workingLongSide = 1280;
  // Phone cameras are ~60° wide; used only for the cylindrical pre-warp.
  static const _assumedHorizontalFov = 60 * math.pi / 180;

  // --- Photometric/geometric yaw-search recovery ---
  // When an image has no usable direct or triangulated feature evidence at
  // all, its position is instead searched for directly against the
  // panorama already built from the reliably placed images, scored with
  // several independent alignment signals at each candidate yaw - not just
  // SIFT/ORB feature correspondences. An image is only accepted this way
  // when at least two of those signals individually clear their own bar and
  // the combined score clears a higher bar still (mirrors the feature
  // stage's "mutual corroboration" gate above), so this is never just a
  // lowered feature-match threshold - see [_searchYaw].
  static const _yawSearchMaxPasses = 3;
  static const _yawSearchMinOverlapFraction = 0.12;
  static const _yawSearchCandidatesPerImage = 8;
  static const _yawSearchMinPeakScore = 0.15;
  // Combined-score weights; sum to 1. Photometric correlation and edge
  // structure carry the most weight since they hold up best on the kind of
  // image that reaches this stage at all (soft/blurred/noisy enough to have
  // already failed feature matching) - phase correlation and block-matching
  // flow consistency still contribute, but weighted so that two solidly
  // corroborating signals (not necessarily all five) can clear the combined
  // bar below, matching the "two independent signals agree" philosophy the
  // feature-matching stage already uses.
  static const _yawWPhotometric = 0.32;
  static const _yawWEdge = 0.22;
  static const _yawWPhaseCorr = 0.18;
  static const _yawWFlow = 0.18;
  static const _yawWFeature = 0.10;
  // Per-signal bars for the "at least two signals individually clear their
  // own bar" corroboration gate.
  static const _yawSearchPhotometricBar = 0.55;
  static const _yawSearchEdgeBar = 0.45;
  static const _yawSearchPhaseCorrBar = 0.15;
  static const _yawSearchFlowBar = 0.5;
  // Below the maximum reachable by the two heaviest-weighted signals alone
  // (photometric+edge, 0.54) but well above what either reaching its own bar
  // alone would produce (0.275) - so acceptance needs genuinely strong, not
  // merely bar-level, agreement from at least two signals.
  static const _yawSearchAcceptCombined = 0.38;
  // A candidate must land within this many degrees of some already-placed
  // image to count as plausibly sitting among the known anchors, and not
  // this close to one to avoid placing it on top of an existing image.
  static const _yawSearchMaxGapToNeighborDeg = 70.0;
  static const _yawSearchDuplicateGuardDeg = 5.0;

  // --- In-order stitching ---
  // A weak visual estimate (one detector/direction only) is accepted for a
  // link when it lands this close to what the compass/step predicts - the
  // sensor acting as the second, independent corroborating estimate.
  static const _sensorAgreementDeg = 15.0;
  // Even a strong visual match is overruled by the sensor when they disagree
  // by more than this: indoor compass error is typically well inside it, so
  // a larger gap means the match locked onto repeated structure.
  static const _maxSensorDisagreementDeg = 35.0;
  // Closing-loop error larger than this is reported but not spread over the
  // links, since correcting by that much would distort good links.
  static const _maxLoopCorrectionDeg = 45.0;

  /// Stitches [imagePaths] in the order they were taken: each image is joined
  /// only to the one before it, and, when [closesLoop], the last back to the
  /// first. No image is ever left out - a link with no usable visual overlap
  /// is placed from the difference between the two images' [headingsDeg], or
  /// failing that [stepDeg]. Throws [PanoramaStitchException] only when such
  /// a link has neither.
  static Future<PanoramaStitchResult> stitchInOrder(
    List<String> imagePaths,
    String outputPath, {
    List<double?>? headingsDeg,
    double? stepDeg,
    bool closesLoop = false,
  }) => Isolate.run(
    () => _stitchInOrder(imagePaths, outputPath, headingsDeg, stepDeg, closesLoop),
  );

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
  cv.VecKeyPoint? orbKeypoints;
  cv.Mat? orbDescriptors;
  // Computed lazily, only for images that reach the yaw-search recovery
  // stage - a third, independent detector family on top of SIFT/ORB used
  // for every pair up front (see [_ensureAkaze]).
  cv.VecKeyPoint? akazeKeypoints;
  cv.Mat? akazeDescriptors;
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
}

/// One detector+direction's homography estimate for a pair, always expressed
/// as mapping the higher-indexed image's coordinates into the lower-indexed
/// image's, so estimates from different detectors/directions are directly
/// comparable.
class _Estimate {
  const _Estimate(this.family, this.hHigherToLower, this.good, this.inliers);
  final String family;
  final List<double> hHigherToLower;
  final int good;
  final int inliers;
  double get tx => hHigherToLower[2] / hHigherToLower[8];
  bool get meetsWeak =>
      good >= PanoramaStitcher._weakMinGoodMatches &&
      inliers >= PanoramaStitcher._weakMinInliers &&
      inliers / good >= PanoramaStitcher._weakMinInlierRatio;
  bool get meetsStrong =>
      good >= PanoramaStitcher._minGoodMatches &&
      inliers >= PanoramaStitcher._minInliers &&
      inliers / good >= PanoramaStitcher._minInlierRatio;
}

/// A validated link between two images: [hHigherToLower] maps [higher]'s
/// cylindrical coordinates into [lower]'s ([higher] > [lower]).
class _Edge {
  const _Edge(
    this.lower,
    this.higher,
    this.hHigherToLower,
    this.good,
    this.inliers,
    this.corroborated, {
    this.viaYawSearch = false,
  });
  final int lower;
  final int higher;
  final List<double> hHigherToLower;
  final int good;
  final int inliers;
  final bool corroborated;
  /// True when this edge came from the photometric/geometric yaw-search
  /// recovery stage (matchTemplate/phase-correlation/edge/flow-consistency
  /// signals against the panorama-so-far, or a direct closing check between
  /// the two angular extremes) rather than any feature correspondence. Such
  /// an edge's [good]/[inliers] are a synthetic weight derived from its
  /// combined score, not a literal match/RANSAC-inlier count.
  final bool viaYawSearch;
}

PanoramaStitchResult _stitch(List<String> paths, String outputPath) {
  if (paths.length < 2) {
    throw const PanoramaStitchException('input', 'At least 2 images required');
  }
  final sift = cv.SIFT.create(nfeatures: 4000);
  final siftMatcher = cv.BFMatcher.create(type: cv.NORM_L2);
  final orb = cv.ORB.create(nFeatures: PanoramaStitcher._orbFeatures);
  final orbMatcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
  // AKAZE also produces a binary (MLDB) descriptor, so it shares orbMatcher
  // (NORM_HAMMING) rather than needing its own matcher instance. Only used
  // by the yaw-search recovery stage, lazily, for images that reach it.
  final akaze = cv.AKAZE.create();
  final frames = <_Frame>[];
  try {
    return _stitchFrames(paths, outputPath, sift, siftMatcher, orb, orbMatcher, akaze, frames);
  } finally {
    // Runs on every exit path (success or a PanoramaStitchException), so a
    // failed/retried stitch never leaks the native Mats/keypoints/descriptors
    // of the frames that were already prepared.
    _disposeFrames(frames);
    orb.dispose();
    orbMatcher.dispose();
    akaze.dispose();
  }
}

void _disposeFrames(List<_Frame> frames) {
  for (final f in frames) {
    f.image.dispose();
    f.mask.dispose();
    f.keypoints.dispose();
    f.descriptors.dispose();
    f.orbKeypoints?.dispose();
    f.orbDescriptors?.dispose();
    f.akazeKeypoints?.dispose();
    f.akazeDescriptors?.dispose();
  }
}

PanoramaStitchResult _stitchInOrder(
  List<String> paths,
  String outputPath,
  List<double?>? headingsDeg,
  double? stepDeg,
  bool closesLoop,
) {
  if (paths.length < 2) {
    throw const PanoramaStitchException('input', 'At least 2 images required');
  }
  final sift = cv.SIFT.create(nfeatures: 4000);
  final siftMatcher = cv.BFMatcher.create(type: cv.NORM_L2);
  final orb = cv.ORB.create(nFeatures: PanoramaStitcher._orbFeatures);
  final orbMatcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
  final frames = <_Frame>[];
  try {
    var keypointCount = 0;
    for (var i = 0; i < paths.length; i++) {
      // A frame with little texture is still kept: its links fall back to
      // the sensor instead of failing the panorama.
      final frame = _prepare(paths[i], i + 1, sift, minKeypoints: 0);
      _ensureOrb(frame, orb);
      keypointCount += frame.keypoints.length;
      frames.add(frame);
    }
    final n = frames.length;
    final f = frames.first.f;
    var totalMatches = 0, goodMatches = 0, inlierCount = 0;

    // Angles here are clockwise turns in degrees, the same sense as a compass
    // heading: turning right puts the next shot's content to the right, so it
    // lands at a larger x on the canvas.
    //
    // The rotation from image [from] to image [to] that the sensors predict.
    double? expectedDelta(int from, int to) {
      final a = headingsDeg?[from], b = headingsDeg?[to];
      if (a != null && b != null) return _angleDiffDeg(b, a);
      return stepDeg;
    }

    // Resolves one link, [from] -> [to], to a rotation: the visual match when
    // it is trustworthy, otherwise the sensor prediction.
    ({double delta, bool sensor, String basis})? link(int from, int to) {
      final pair = _estimatePair(frames[from], frames[to], siftMatcher, orbMatcher);
      totalMatches += pair.totalMatches;
      final expected = expectedDelta(from, to);
      final classified = _classifyPair(from, to, pair.estimates);
      String? rejected;
      if (classified != null) {
        final edge = classified.edge;
        final visual = -_effectiveAngleDeg(edge.hHigherToLower, f);
        final disagreement = expected == null ? 0.0 : (visual - expected).abs();
        final accept = classified.strong
            ? disagreement <= PanoramaStitcher._maxSensorDisagreementDeg
            : expected != null && disagreement <= PanoramaStitcher._sensorAgreementDeg;
        if (accept) {
          goodMatches += edge.good;
          inlierCount += edge.inliers;
          final how = classified.strong
              ? 'mutually corroborated SIFT/ORB match'
              : 'single visual match corroborated by the sensor';
          return (
            delta: visual,
            sensor: false,
            basis: '$how, ${edge.inliers} inliers of ${edge.good} good matches',
          );
        }
        rejected = '${classified.strong ? 'strong' : 'weak'} visual match at '
            '${visual.toStringAsFixed(1)}° disagreed with the expected '
            '${expected?.toStringAsFixed(1) ?? '?'}°';
      }
      if (expected == null) return null;
      final source = headingsDeg?[from] != null && headingsDeg?[to] != null
          ? 'compass heading difference'
          : 'expected ${stepDeg!.toStringAsFixed(0)}° step';
      return (
        delta: expected,
        sensor: true,
        basis: '$source - ${rejected ?? 'no trustworthy visual overlap'}',
      );
    }

    final deltas = <double>[];
    final sensorLinks = <int>[];
    final bases = <String>[];
    for (var i = 0; i + 1 < n; i++) {
      final resolved = link(i, i + 1);
      if (resolved == null) {
        throw PanoramaStitchException(
          'matching',
          'no trustworthy visual overlap, and no heading or step to place it by',
          pair: i + 1,
        );
      }
      deltas.add(resolved.delta);
      bases.add(resolved.basis);
      if (resolved.sensor) sensorLinks.add(i + 1);
    }

    // Closing the loop: the links around a full turn must add up to 360°.
    // Any discrepancy is spread over the sensor-placed links first, since
    // they're the least precise; over all links when every one was visual.
    double? loopClosureErrorDeg;
    var loopClosed = false;
    if (closesLoop && n >= 3) {
      final closing = link(n - 1, 0);
      if (closing != null) {
        if (closing.sensor) sensorLinks.add(n);
        final error = deltas.fold(0.0, (a, b) => a + b) + closing.delta - 360;
        loopClosureErrorDeg = error.abs();
        if (error.abs() <= PanoramaStitcher._maxLoopCorrectionDeg) {
          loopClosed = true;
          final absorbing = [
            for (var k = 0; k < deltas.length; k++)
              if (sensorLinks.contains(k + 1)) k,
          ];
          final targets = absorbing.isEmpty ? [for (var k = 0; k < deltas.length; k++) k] : absorbing;
          // The closing link takes its share too when it is one of them.
          final shares = targets.length + (closing.sensor || absorbing.isEmpty ? 1 : 0);
          for (final k in targets) {
            deltas[k] -= error / shares;
          }
        }
      }
    }

    final angle = <double>[0];
    for (final d in deltas) {
      angle.add(angle.last + d);
    }
    final placed = [for (var i = 0; i < n; i++) i];
    final global = <int, List<double>>{
      for (final i in placed) i: <double>[1, 0, f * angle[i] * math.pi / 180, 0, 1, 0, 0, 0, 1],
    };
    final (:width, :height) = _compositeAndWrite(
      frames,
      placed,
      global,
      0,
      outputPath,
      maxWidth: loopClosed ? (2 * math.pi * f).round() : null,
    );
    return PanoramaStitchResult(
      path: outputPath,
      width: width,
      height: height,
      keypointCount: keypointCount,
      totalMatches: totalMatches,
      goodMatches: goodMatches,
      inlierCount: inlierCount,
      usedImageCount: n,
      droppedImages: const [],
      dropReasons: const {},
      recoveredImages: const [],
      recoveredViaGeometricSearch: const [],
      yawSearchDiagnostics: const {},
      pairDiagnostics: [
        for (var i = 1; i < n; i++)
          'image ${i + 1}: placed at ${angle[i].toStringAsFixed(1)}° after image $i (${bases[i - 1]})',
      ],
      loopClosureErrorDeg: loopClosureErrorDeg,
      sensorPlacedLinks: sensorLinks,
    );
  } finally {
    _disposeFrames(frames);
    orb.dispose();
    orbMatcher.dispose();
  }
}

PanoramaStitchResult _stitchFrames(
  List<String> paths,
  String outputPath,
  cv.SIFT sift,
  cv.BFMatcher siftMatcher,
  cv.ORB orb,
  cv.BFMatcher orbMatcher,
  cv.AKAZE akaze,
  List<_Frame> frames,
) {
  var keypointCount = 0;
  for (var i = 0; i < paths.length; i++) {
    final frame = _prepare(paths[i], i + 1, sift);
    keypointCount += frame.keypoints.length;
    frames.add(frame);
  }
  final n = frames.length;
  // A second, complementary detector for every image up front - not just for
  // images that turn out to need recovery - since cross-detector agreement
  // is now part of how an ordinary pair gets validated at all (see
  // [_classifyPair]).
  for (final frame in frames) {
    _ensureOrb(frame, orb);
  }

  // Try every pair, with no assumed order or adjacency, using both SIFT and
  // ORB in both matching directions. A pair only becomes strong evidence
  // when at least two of these independent estimates agree closely with each
  // other (mutual matching, rejecting a false correspondence that only shows
  // up from a single detector in a single direction), and at least one of
  // the agreeing estimates individually clears the full bar. An
  // individually-strong estimate with no independent corroboration is kept
  // at the weak tier instead of discarded outright, since it can still be
  // legitimate recovery evidence once triangulated against a third image.
  final strongEdges = <_Edge>[];
  final weakEdges = <_Edge>[];
  var totalMatches = 0;
  for (var lower = 0; lower < n; lower++) {
    for (var higher = lower + 1; higher < n; higher++) {
      final pair = _estimatePair(frames[lower], frames[higher], siftMatcher, orbMatcher);
      totalMatches += pair.totalMatches;
      final estimates = pair.estimates;

      final classified = _classifyPair(lower, higher, estimates);
      if (classified == null) continue;
      if (classified.strong) {
        strongEdges.add(classified.edge);
      } else {
        weakEdges.add(classified.edge);
      }
    }
  }

  // Build a maximum-spanning forest (by inlier count) over *every* strong
  // edge, not just ones touching the eventual largest group - so that if two
  // images are strongly linked to each other but not to the main group, and
  // recovery later bridges just one of them into it, the other becomes
  // reachable through their own edge already sitting in this forest, with no
  // extra recovery needed for it.
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

  // Each image's position is tracked as a single rotation angle, not a
  // composed homography - a panoramic-rotation camera model (per
  // requirement) rather than chaining arbitrary planar transforms. This also
  // sidesteps a real bug chained matrix composition had: each edge's scale
  // (det) individually passes the plausibility check, but multiplying
  // several of them along a long path compounds that scale error, which can
  // blow a corner position up to something absurd even though every
  // individual edge was fine. Angle deltas simply add, however long the
  // path, so that can't happen.
  var goodMatches = 0, inlierCount = 0;
  final reference = (core.toList()..sort()).first;
  final f = frames[reference].f;
  final angle = List<double?>.filled(n, null);
  angle[reference] = 0;
  final placedVia = <int, _Edge>{};
  void expand(int start) {
    final queue = <int>[start];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final edge in adjacency[current]) {
        final other = edge.lower == current ? edge.higher : edge.lower;
        if (angle[other] != null) continue;
        final delta = _effectiveAngleDeg(edge.hHigherToLower, f);
        angle[other] = other == edge.higher ? angle[current]! + delta : angle[current]! - delta;
        goodMatches += edge.good;
        inlierCount += edge.inliers;
        placedVia[other] = edge;
        queue.add(other);
      }
    }
  }

  expand(reference);

  // Recovery for anything not reached above: check whether two independently
  // weak matches to two different placed images agree on where it belongs -
  // agreement between two unrelated weak signals is real corroborating
  // evidence, so this recovers a genuine connection without ever lowering
  // what counts as "connected". Recovering one image can newly enable
  // triangulation for another, so this repeats until a full pass makes no
  // further progress.
  final recovered = <int>[];
  final bestEvidence = <int, String>{};
  var pass = 0;
  var unplaced = [for (var i = 0; i < n; i++) if (angle[i] == null) i];
  while (unplaced.isNotEmpty && pass < PanoramaStitcher._maxRecoveryPasses) {
    pass++;
    var progressed = false;
    for (final d in unplaced) {
      if (angle[d] != null) continue; // placed earlier this pass via triangulation
      final placedNow = [for (var i = 0; i < n; i++) if (angle[i] != null) i];

      final candidates = <(int other, List<double> hDToOther, int good, int inliers)>[];
      for (final edge in weakEdges) {
        if (edge.lower != d && edge.higher != d) continue;
        final other = edge.lower == d ? edge.higher : edge.lower;
        if (!placedNow.contains(other)) continue;
        final hDToOther = edge.higher == d ? edge.hHigherToLower : _invert3x3(edge.hHigherToLower);
        candidates.add((other, hDToOther, edge.good, edge.inliers));
      }

      _Edge? accepted;
      var bestDisagreement = double.infinity;
      for (var i = 0; i < candidates.length; i++) {
        for (var j = i + 1; j < candidates.length; j++) {
          final (c1, hDTo1, good1, inliers1) = candidates[i];
          final (c2, hDTo2, good2, inliers2) = candidates[j];
          if (c1 == c2) continue;
          final angle1 = angle[c1]! + _effectiveAngleDeg(hDTo1, f);
          final angle2 = angle[c2]! + _effectiveAngleDeg(hDTo2, f);
          final disagreement = _angleDiffDeg(angle1, angle2).abs();
          if (disagreement < bestDisagreement) bestDisagreement = disagreement;
          if (disagreement <= PanoramaStitcher._triangulationToleranceDeg) {
            final better = inliers1 >= inliers2
                ? _Edge(math.min(d, c1), math.max(d, c1),
                    d < c1 ? _invert3x3(hDTo1) : hDTo1, good1, inliers1, true)
                : _Edge(math.min(d, c2), math.max(d, c2),
                    d < c2 ? _invert3x3(hDTo2) : hDTo2, good2, inliers2, true);
            if (accepted == null || better.inliers > accepted.inliers) accepted = better;
          }
        }
      }
      if (accepted != null) {
        final other = accepted.lower == d ? accepted.higher : accepted.lower;
        final delta = _effectiveAngleDeg(accepted.hHigherToLower, f);
        angle[d] = accepted.higher == d ? angle[other]! + delta : angle[other]! - delta;
        adjacency[d].add(accepted);
        adjacency[other].add(accepted);
        goodMatches += accepted.good;
        inlierCount += accepted.inliers;
        placedVia[d] = accepted;
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
            '${(PanoramaStitcher._minInlierRatio * 100).round()}% ratio required, '
            'and not independently corroborated by another detector; '
            'no second independent match to a different image agreed closely '
            'enough either (closest disagreement '
            '${bestDisagreement.isFinite ? '${bestDisagreement.toStringAsFixed(1)}°' : 'n/a'} '
            'vs the ${PanoramaStitcher._triangulationToleranceDeg.toStringAsFixed(0)}° tolerance)';
      } else {
        bestEvidence[d + 1] =
            'no candidate match (even a weak one, with SIFT or ORB) was found '
            'against any other image';
      }
    }
    unplaced = [for (var i = 0; i < n; i++) if (angle[i] == null) i];
    if (!progressed) break;
  }

  // Stage 2: photometric/geometric yaw-search recovery. Anything still
  // unplaced after direct and triangulated feature evidence gets one more,
  // stronger attempt: search for where its cylindrical projection actually
  // lines up against the panorama already built from the reliably placed
  // images, scored with several independent alignment signals (matchTemplate
  // correlation, phase correlation, edge-structure correlation, a
  // block-matching flow-consistency check, and SIFT/ORB/AKAZE feature
  // evidence for that specific position) rather than requiring a pairwise
  // feature match to have succeeded on its own. An image is only accepted
  // when at least two of these independent signals individually clear their
  // own bar and the combined score clears a higher bar still - the same
  // "mutual corroboration" philosophy as the feature stage above, with
  // photometric signals standing in for a second detector/direction, so
  // this never amounts to just lowering the feature-match threshold. Runs in
  // passes: recovering one image can open up a second, better-supported
  // anchor for another (e.g. recovering image 3 first gives image 1 two
  // neighbours to be tested against, not one) - so every still-unplaced
  // image is tested against the *whole* panorama built so far each pass, not
  // only its immediate neighbours.
  final recoveredViaGeometricSearch = <int>[];
  final yawSearchDiagnostics = <int, List<String>>{};
  var yawPass = 0;
  var stillUnplaced = [for (var i = 0; i < n; i++) if (angle[i] == null) i];
  while (stillUnplaced.isNotEmpty && yawPass < PanoramaStitcher._yawSearchMaxPasses) {
    yawPass++;
    final placedForComposite = [for (var i = 0; i < n; i++) if (angle[i] != null) i];
    if (placedForComposite.length < 2) break;
    final composite = _compositeForScoring(placedForComposite, angle, frames, f);
    var progressed = false;
    for (final d in stillUnplaced) {
      if (angle[d] != null) continue; // placed earlier this pass
      final signals =
          _searchYaw(frames[d], composite.gray, composite.coverage, composite.worldXAtCol0, f);
      final lines = <String>[];
      _YawSignal? acceptedSignal;
      var acceptedCombined = 0.0;
      var acceptedFeatureInliers = 0;
      var acceptedSupport = const <int>[];

      for (final s in signals) {
        // Which existing images this candidate is closest to - tested
        // against the whole panorama above, then cross-checked here against
        // its two nearest anchors specifically (item 7/8).
        final nearest = placedForComposite.toList()
          ..sort((a, b) =>
              (angle[a]! - s.angleDeg).abs().compareTo((angle[b]! - s.angleDeg).abs()));
        final support = nearest.take(2).toList();
        final minGap = support.isEmpty ? double.infinity : (angle[support.first]! - s.angleDeg).abs();
        if (support.isNotEmpty && minGap < PanoramaStitcher._yawSearchDuplicateGuardDeg) {
          lines.add(_yawCandidateLine(s, 0, support, 0, false, 'coincides with an already-placed image'));
          continue;
        }
        if (minGap > PanoramaStitcher._yawSearchMaxGapToNeighborDeg) {
          lines.add(_yawCandidateLine(s, 0, support, 0, false, 'too far from any placed anchor'));
          continue;
        }

        // Feature evidence for this specific position: whatever SIFT/ORB
        // evidence already exists from the all-pairs pass above (even
        // below the "weak" edge bar on its own), plus a fresh AKAZE
        // attempt - a third, independent detector family, run lazily since
        // most images never reach this stage.
        var featureInliers = 0;
        for (final edge in weakEdges) {
          if (edge.lower != d && edge.higher != d) continue;
          final other = edge.lower == d ? edge.higher : edge.lower;
          if (support.contains(other)) featureInliers = math.max(featureInliers, edge.inliers);
        }
        if (support.isNotEmpty) {
          final anchor = support.first;
          _ensureAkaze(frames[d], akaze);
          _ensureAkaze(frames[anchor], akaze);
          final fwd = _matchAndValidate(
            frames[d].akazeKeypoints!,
            frames[d].akazeDescriptors!,
            frames[anchor].akazeKeypoints!,
            frames[anchor].akazeDescriptors!,
            orbMatcher,
          );
          featureInliers = math.max(featureInliers, fwd.inliers);
        }
        final featureScore = (featureInliers / PanoramaStitcher._minInliers).clamp(0.0, 1.0);

        final combined = PanoramaStitcher._yawWPhotometric * s.photometric +
            PanoramaStitcher._yawWPhaseCorr * s.phaseCorr +
            PanoramaStitcher._yawWEdge * s.edge +
            PanoramaStitcher._yawWFlow * s.flow +
            PanoramaStitcher._yawWFeature * featureScore;
        final clearedBars = [
          s.photometric >= PanoramaStitcher._yawSearchPhotometricBar,
          s.phaseCorr >= PanoramaStitcher._yawSearchPhaseCorrBar,
          s.edge >= PanoramaStitcher._yawSearchEdgeBar,
          s.flow >= PanoramaStitcher._yawSearchFlowBar,
          featureInliers > 0,
        ].where((v) => v).length;
        final accept =
            combined >= PanoramaStitcher._yawSearchAcceptCombined && clearedBars >= 2;

        lines.add(_yawCandidateLine(s, featureInliers, support, combined, accept, null));
        if (accept && combined > acceptedCombined) {
          acceptedSignal = s;
          acceptedCombined = combined;
          acceptedFeatureInliers = featureInliers;
          acceptedSupport = support;
        }
      }
      yawSearchDiagnostics[d + 1] = lines;

      if (acceptedSignal != null) {
        angle[d] = acceptedSignal.angleDeg;
        final pseudoWeight = math.max(1, (acceptedCombined * 100).round());
        for (final other in acceptedSupport) {
          final lower = math.min(d, other), higher = math.max(d, other);
          final delta = angle[higher]! - angle[lower]!;
          final edge = _Edge(
            lower,
            higher,
            _pureRotation(delta, f),
            math.max(pseudoWeight, acceptedFeatureInliers),
            pseudoWeight,
            true,
            viaYawSearch: true,
          );
          adjacency[d].add(edge);
          adjacency[other].add(edge);
          placedVia.putIfAbsent(d, () => edge);
        }
        recoveredViaGeometricSearch.add(d + 1);
        progressed = true;
      } else {
        final summary = lines.isEmpty
            ? 'no candidate yaw had enough overlap (${(PanoramaStitcher._yawSearchMinOverlapFraction * 100).round()}%+) with the panorama built so far'
            : 'best combined score ${signals.isEmpty ? 'n/a' : (acceptedCombined == 0 ? "below the ${PanoramaStitcher._yawSearchAcceptCombined} bar" : acceptedCombined.toStringAsFixed(2))} across ${lines.length} candidate yaw(s) considered';
        final existing = bestEvidence[d + 1];
        bestEvidence[d + 1] =
            '${existing == null ? '' : '$existing; '}geometric yaw-search: $summary';
      }
    }
    composite.gray.dispose();
    composite.coverage.dispose();
    stillUnplaced = [for (var i = 0; i < n; i++) if (angle[i] == null) i];
    if (!progressed) break;
  }

  final placed = [for (var i = 0; i < n; i++) if (angle[i] != null) i]..sort();
  final dropped = [for (var i = 0; i < n; i++) if (angle[i] == null) i + 1];
  final dropReasons = {for (final d in dropped) d: bestEvidence[d] ?? 'no evidence found'};

  // Feed the refinement below every remaining strong edge too, not just the
  // spanning-tree ones used to reach each image - an actual bundle-style
  // joint refinement using all reliable evidence at once, including
  // whatever extra loop-closing redundancy the graph happens to contain.
  final placedSet = placed.toSet();
  final allTrackedEdges = <_Edge>[...strongEdges, ...weakEdges];
  for (final edge in strongEdges) {
    if (!placedSet.contains(edge.lower) || !placedSet.contains(edge.higher)) continue;
    final alreadyIn = adjacency[edge.lower].any((e) =>
        (e.lower == edge.lower && e.higher == edge.higher) ||
        (e.lower == edge.higher && e.higher == edge.lower));
    if (!alreadyIn) {
      adjacency[edge.lower].add(edge);
      adjacency[edge.higher].add(edge);
    }
  }

  // Circular-constraint check: if the two current angular extremes aren't
  // already linked by any accepted edge, test them directly against each
  // other with the same multi-signal search used for recovery above,
  // restricted to the angular neighbourhood where a closing edge would have
  // to sit. A genuine continuous 360° sweep's first and last images should
  // show some real overlap even when no feature match was strong enough to
  // find it on its own; the sequence only closes into a loop when this
  // clears the same bar as any other recovery, never unconditionally (item
  // 9-11).
  if (placed.length >= 3) {
    final sortedByAngle = placed.toList()..sort((a, b) => angle[a]!.compareTo(angle[b]!));
    final lo = sortedByAngle.first, hi = sortedByAngle.last;
    final alreadyLinked = adjacency[lo]
        .any((e) => (e.lower == lo && e.higher == hi) || (e.lower == hi && e.higher == lo));
    if (!alreadyLinked) {
      final loGray = cv.cvtColor(frames[lo].image, cv.COLOR_BGR2GRAY);
      final signals =
          _searchYaw(frames[hi], loGray, frames[lo].mask, -f * angle[lo]! * math.pi / 180, f);
      loGray.dispose();
      _YawSignal? best;
      var bestCombined = 0.0;
      var bestFeatureInliers = 0;
      for (final s in signals) {
        // Only a candidate near hi's own already-established position
        // counts - this validates/discovers the wrap-around overlap that
        // should exist there, it does not search for some unrelated spot.
        if ((s.angleDeg - angle[hi]!).abs() > PanoramaStitcher._yawSearchMaxGapToNeighborDeg) continue;
        var featureInliers = 0;
        for (final edge in weakEdges) {
          if ((edge.lower == lo && edge.higher == hi) || (edge.lower == hi && edge.higher == lo)) {
            featureInliers = math.max(featureInliers, edge.inliers);
          }
        }
        final featureScore = (featureInliers / PanoramaStitcher._minInliers).clamp(0.0, 1.0);
        final combined = PanoramaStitcher._yawWPhotometric * s.photometric +
            PanoramaStitcher._yawWPhaseCorr * s.phaseCorr +
            PanoramaStitcher._yawWEdge * s.edge +
            PanoramaStitcher._yawWFlow * s.flow +
            PanoramaStitcher._yawWFeature * featureScore;
        final clearedBars = [
          s.photometric >= PanoramaStitcher._yawSearchPhotometricBar,
          s.phaseCorr >= PanoramaStitcher._yawSearchPhaseCorrBar,
          s.edge >= PanoramaStitcher._yawSearchEdgeBar,
          s.flow >= PanoramaStitcher._yawSearchFlowBar,
          featureInliers > 0,
        ].where((v) => v).length;
        if (combined >= PanoramaStitcher._yawSearchAcceptCombined &&
            clearedBars >= 2 &&
            combined > bestCombined) {
          best = s;
          bestCombined = combined;
          bestFeatureInliers = featureInliers;
        }
      }
      if (best != null) {
        final delta = best.angleDeg - angle[lo]!;
        final closingEdge = _Edge(
          math.min(lo, hi),
          math.max(lo, hi),
          lo < hi ? _pureRotation(delta, f) : _pureRotation(-delta, f),
          math.max(1, bestFeatureInliers),
          math.max(1, (bestCombined * 100).round()),
          true,
          viaYawSearch: true,
        );
        adjacency[lo].add(closingEdge);
        adjacency[hi].add(closingEdge);
        allTrackedEdges.add(closingEdge);
      }
    }
  }

  // Global refinement: every placed image's angle is re-estimated as the
  // inlier-weighted average of what *every* edge touching it predicts (not
  // just the single edge it was originally reached through), jointly
  // minimizing disagreement across all reliable matches at once - including
  // whatever loop-closure redundancy the evidence graph happens to contain
  // (e.g. a 4-image cluster connected by more edges than the 3 a spanning
  // tree would use). Differences are measured, not raw angles averaged, so
  // this stays correct across the 0/360 wrap.
  for (var iter = 0; iter < 25; iter++) {
    var maxChange = 0.0;
    for (final i in placed) {
      if (i == reference) continue;
      var weightedDiffSum = 0.0, totalWeight = 0.0;
      for (final edge in adjacency[i]) {
        final other = edge.lower == i ? edge.higher : edge.lower;
        if (angle[other] == null) continue;
        final delta = _effectiveAngleDeg(edge.hHigherToLower, f);
        final predicted = i == edge.higher ? angle[other]! + delta : angle[other]! - delta;
        final weight = edge.inliers.toDouble();
        weightedDiffSum += _angleDiffDeg(predicted, angle[i]!) * weight;
        totalWeight += weight;
      }
      if (totalWeight <= 0) continue;
      final adjustment = weightedDiffSum / totalWeight;
      maxChange = math.max(maxChange, adjustment.abs());
      angle[i] = angle[i]! + adjustment;
    }
    if (maxChange < 0.01) break;
  }

  // Reconstruct the full matrix each placed image needs for warping from its
  // final, globally-refined angle - a pure horizontal shift, so no
  // accumulated scale/perspective drift from the graph traversal above can
  // reach the actual geometry.
  final global = <int, List<double>>{
    for (final i in placed) i: <double>[1, 0, -f * angle[i]! * math.pi / 180, 0, 1, 0, 0, 0, 1],
  };

  // Diagnostics: the accepted link for every placed image (except the
  // reference), its evidence, and whether it needed triangulated recovery.
  final pairDiagnostics = [
    for (final i in placed)
      if (i != reference)
        () {
          final edge = placedVia[i]!;
          final via = edge.lower == i ? edge.higher : edge.lower;
          final basis = edge.viaYawSearch
              ? 'photometric/geometric yaw-search (multi-signal correlation against the panorama, not a feature match)'
              : edge.corroborated
                  ? 'triangulated agreement (2+ independent matches)'
                  : 'mutually corroborated direct match';
          return 'image ${i + 1}: placed at ${angle[i]!.toStringAsFixed(1)}° via image '
              '${via + 1} ($basis, ${edge.inliers} inliers of ${edge.good} good matches)';
        }(),
  ];

  // Loop-closure diagnostic: if the two angular extremes of the placed set
  // are themselves linked by a candidate edge that wasn't used for
  // placement, check how well it agrees with the rest of the chain.
  double? loopClosureErrorDeg;
  if (placed.length >= 3) {
    final sortedByAngle = placed.toList()..sort((a, b) => angle[a]!.compareTo(angle[b]!));
    final lo = sortedByAngle.first, hi = sortedByAngle.last;
    final closing = allTrackedEdges.where(
      (e) => (e.lower == lo && e.higher == hi) || (e.lower == hi && e.higher == lo),
    ).toList()
      ..sort((a, b) => b.inliers.compareTo(a.inliers));
    if (closing.isNotEmpty) {
      final edge = closing.first;
      final chainDelta = _angleDiffDeg(angle[hi]!, angle[lo]!);
      final edgeDelta = edge.higher == hi
          ? _effectiveAngleDeg(edge.hHigherToLower, f)
          : -_effectiveAngleDeg(edge.hHigherToLower, f);
      loopClosureErrorDeg = _angleDiffDeg(chainDelta, edgeDelta).abs();
    }
  }

  final (:width, :height) = _compositeAndWrite(frames, placed, global, reference, outputPath);
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
    recoveredViaGeometricSearch: recoveredViaGeometricSearch,
    yawSearchDiagnostics: yawSearchDiagnostics,
    pairDiagnostics: pairDiagnostics,
    loopClosureErrorDeg: loopClosureErrorDeg,
  );
}

/// Warps every [placed] frame by its [global] placement onto one canvas,
/// composites winner-takes-one, crops to the fully covered rectangle, writes
/// the JPEG to [outputPath] and validates it on disk. Shared by the unordered
/// and in-order pipelines, which differ only in how they find [global].
/// [maxWidth] trims a closed 360° loop to exactly one turn, so the content
/// that wraps past the first frame doesn't appear twice.
({int width, int height}) _compositeAndWrite(
  List<_Frame> frames,
  List<int> placed,
  Map<int, List<double>> global,
  int reference,
  String outputPath, {
  int? maxWidth,
}) {
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
    roi: cv.Rect(crop.left, crop.top, math.min(crop.width, maxWidth ?? crop.width), crop.height),
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
  return (width: width, height: height);
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

/// Computes AKAZE keypoints/descriptors for [frame] if not already cached -
/// a third, independent detector family used only by the yaw-search recovery
/// stage, lazily, since the images that never need recovery never pay for it.
void _ensureAkaze(_Frame frame, cv.AKAZE akaze) {
  if (frame.akazeDescriptors != null) return;
  final gray = cv.cvtColor(frame.image, cv.COLOR_BGR2GRAY);
  final (kp, desc) = akaze.detectAndCompute(gray, frame.mask);
  gray.dispose();
  frame.akazeKeypoints = kp;
  frame.akazeDescriptors = desc;
}

/// Every validated homography estimate for how [higher] sits relative to
/// [lower] - SIFT and ORB, each matched in both directions - expressed as
/// mapping [higher]'s coordinates into [lower]'s. A frame with too few
/// features for a detector simply contributes no estimate from it.
({List<_Estimate> estimates, int totalMatches}) _estimatePair(
  _Frame lower,
  _Frame higher,
  cv.BFMatcher siftMatcher,
  cv.BFMatcher orbMatcher,
) {
  final estimates = <_Estimate>[];
  var totalMatches = 0;
  void tryDetector(
    String family,
    cv.VecKeyPoint higherKp,
    cv.Mat higherDesc,
    cv.VecKeyPoint lowerKp,
    cv.Mat lowerDesc,
    cv.BFMatcher detectorMatcher,
  ) {
    if (higherKp.length < 2 || lowerKp.length < 2) return;
    final fwd = _matchAndValidate(higherKp, higherDesc, lowerKp, lowerDesc, detectorMatcher);
    totalMatches += fwd.totalMatches;
    if (fwd.homography != null) {
      estimates.add(_Estimate(family, fwd.homography!, fwd.good, fwd.inliers));
    }
    final bwd = _matchAndValidate(lowerKp, lowerDesc, higherKp, higherDesc, detectorMatcher);
    totalMatches += bwd.totalMatches;
    if (bwd.homography != null) {
      estimates.add(_Estimate(family, _invert3x3(bwd.homography!), bwd.good, bwd.inliers));
    }
  }

  tryDetector('SIFT', higher.keypoints, higher.descriptors, lower.keypoints, lower.descriptors,
      siftMatcher);
  tryDetector('ORB', higher.orbKeypoints!, higher.orbDescriptors!, lower.orbKeypoints!,
      lower.orbDescriptors!, orbMatcher);
  return (estimates: estimates, totalMatches: totalMatches);
}

/// Given every valid (geometrically non-degenerate) estimate found for a
/// pair - from multiple detectors and both matching directions - decides
/// whether the pair counts as strong evidence, weak (recovery-only)
/// evidence, or nothing at all.
///
/// A pair is strong only when at least two independent estimates (any
/// detector, either direction) agree closely on the same geometry, and at
/// least one of the agreeing estimates individually clears the full
/// acceptance bar. This is "mutual matching" as the actual gate, rather than
/// trusting any single fit's own numbers: an isolated one-directional match
/// that no other detector or direction corroborates can still be a
/// coincidental correspondence even with an individually strong inlier
/// count and ratio (observed in practice against this pipeline's own real
/// test data). Such an uncorroborated-but-individually-strong estimate is
/// kept at the weak tier instead of discarded outright, so it remains usable
/// by the separate triangulation recovery, which supplies its own
/// independent (third-image) corroboration before accepting anything.
({_Edge edge, bool strong})? _classifyPair(int lower, int higher, List<_Estimate> estimates) {
  final usable = [for (final e in estimates) if (e.meetsWeak) e];
  if (usable.isEmpty) return null;
  _Estimate? bestStrong;
  _Estimate? bestWeak;
  for (final candidate in usable) {
    final agreeing = [
      candidate,
      for (final other in usable)
        if (!identical(other, candidate) && _agreesOnAngle(candidate.tx, other.tx)) other,
    ];
    final corroborated = agreeing.length >= 2;
    if (corroborated && agreeing.any((e) => e.meetsStrong)) {
      final leader = agreeing.reduce((a, b) => b.inliers > a.inliers ? b : a);
      if (bestStrong == null || leader.inliers > bestStrong.inliers) bestStrong = leader;
    }
    if (bestWeak == null || candidate.inliers > bestWeak.inliers) bestWeak = candidate;
  }
  final chosen = bestStrong ?? bestWeak!;
  return (
    edge: _Edge(lower, higher, chosen.hHigherToLower, chosen.good, chosen.inliers, false),
    strong: bestStrong != null,
  );
}

/// Whether two tx (pixel-shift) values are close enough to call the same
/// underlying rotation.
bool _agreesOnAngle(double tx1, double tx2) {
  final tol = math.max(
    PanoramaStitcher._agreementTolerancePx,
    PanoramaStitcher._agreementToleranceFraction * math.max(tx1.abs(), tx2.abs()),
  );
  return (tx1 - tx2).abs() <= tol;
}

/// Runs kNN matching + the Lowe ratio test + USAC-MAGSAC homography
/// estimation for one pair, returning a validated homography if one exists -
/// never throws, so the caller can just skip an unvalidated pair rather than
/// abort. Works for any detector's keypoints/descriptors (SIFT or ORB),
/// matched with a distance-appropriate matcher (L2 or Hamming respectively).
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
      method: cv.USAC_MAGSAC,
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
_Frame _prepare(String path, int index, cv.SIFT sift, {int minKeypoints = 50}) {
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
  // horizontal pixel shift in this space (a panoramic-rotation camera model),
  // which is what lets homographies between images be chained around a full
  // circle at all.
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
  if (keypoints.length < minKeypoints) {
    throw PanoramaStitchException(
      'features',
      'image $index has only ${keypoints.length} SIFT keypoints (too little texture or too blurry)',
      pair: index,
    );
  }
  return _Frame(cyl, mask, keypoints, descriptors, f);
}

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

/// Inverse of [_effectiveAngleDeg]: the pure-horizontal-shift matrix
/// representing a rotation of [deltaDeg] between two images, in the same
/// convention [_effectiveAngleDeg] reads back (`angle[higher] = angle[lower]
/// + delta`). Used to build synthetic edges for the yaw-search recovery
/// stage, whose evidence is an already-known angle difference rather than a
/// matched homography.
List<double> _pureRotation(double deltaDeg, double f) =>
    <double>[1, 0, -deltaDeg * f * math.pi / 180, 0, 1, 0, 0, 0, 1];

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

/// Builds a lightweight winner-takes-one composite of [subset] at their
/// current [angle]s, in grayscale, purely for the yaw-search recovery stage
/// to score unplaced images against - never shipped, so unlike the final
/// compositing this tracks no owner index and does no blob cleanup or crop.
/// Same warp/blend approach as the final output, so a candidate is scored
/// against genuinely the same pixels it would land among if placed.
/// [worldXAtCol0] is the world x-coordinate (in the same convention as
/// [_apply]/[global] elsewhere in this file) that column 0 of the returned
/// [gray] corresponds to. Caller disposes [gray] and [coverage].
({int width, int height, double worldXAtCol0, cv.Mat gray, cv.Mat coverage})
_compositeForScoring(
  List<int> subset,
  List<double?> angle,
  List<_Frame> frames,
  double f,
) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  final global = <int, List<double>>{};
  for (final i in subset) {
    final g = <double>[1, 0, -f * angle[i]! * math.pi / 180, 0, 1, 0, 0, 0, 1];
    global[i] = g;
    final w = frames[i].image.cols.toDouble(), h = frames[i].image.rows.toDouble();
    for (final c in [
      [0.0, 0.0],
      [w, 0.0],
      [w, h],
      [0.0, h],
    ]) {
      final p = _apply(g, c[0], c[1]);
      minX = math.min(minX, p[0]);
      maxX = math.max(maxX, p[0]);
      minY = math.min(minY, p[1]);
      maxY = math.max(maxY, p[1]);
    }
  }
  final width = (maxX - minX).ceil(), height = (maxY - minY).ceil();
  final shift = <double>[1, 0, -minX, 0, 1, -minY, 0, 0, 1];
  var bestWeight = cv.Mat.zeros(height, width, cv.MatType.CV_32FC1);
  var bestGray = cv.Mat.zeros(height, width, cv.MatType.CV_8UC1);
  final erosionKernel = cv.Mat.ones(11, 11, cv.MatType.CV_8UC1);
  for (final i in subset) {
    final m = cv.Mat.fromList(3, 3, cv.MatType.CV_64FC1, _mul(shift, global[i]!));
    final gray = cv.cvtColor(frames[i].image, cv.COLOR_BGR2GRAY);
    final warped = cv.warpPerspective(gray, m, (width, height));
    final warpedMaskRaw = cv.warpPerspective(
      frames[i].mask,
      m,
      (width, height),
      flags: cv.INTER_NEAREST,
    );
    final warpedMask = cv.erode(warpedMaskRaw, erosionKernel);
    final (dist, labels) = cv.distanceTransform(warpedMask, cv.DIST_L2, 3, cv.DIST_LABEL_CCOMP);
    final dist32 = dist.type == cv.MatType.CV_32FC1 ? dist : dist.convertTo(cv.MatType.CV_32FC1);
    final better = cv.compare(dist32, bestWeight, cv.CMP_GT);
    warped.copyTo(bestGray, mask: better);
    dist32.copyTo(bestWeight, mask: better);
    for (final mat in [m, gray, warped, warpedMaskRaw, warpedMask, dist, labels, better]) {
      mat.dispose();
    }
    if (!identical(dist32, dist)) dist32.dispose();
  }
  erosionKernel.dispose();
  return (width: width, height: height, worldXAtCol0: minX, gray: bestGray, coverage: bestWeight);
}

/// One candidate yaw for an unplaced image, with several independent
/// alignment signals - see [_searchYaw]. All scores are normalised to
/// [0, 1], higher is better.
class _YawSignal {
  const _YawSignal({
    required this.angleDeg,
    required this.overlapFraction,
    required this.photometric,
    required this.phaseCorr,
    required this.edge,
    required this.flow,
  });
  /// Candidate global angle (degrees), refined to sub-pixel precision via
  /// the phase-correlation residual.
  final double angleDeg;
  /// Fraction of the candidate's own pixels that land on already-covered
  /// panorama content at this yaw.
  final double overlapFraction;
  /// Normalised-cross-correlation peak (matchTemplate, TM_CCOEFF_NORMED) -
  /// the primary photometric/correlation signal.
  final double photometric;
  /// cv.phaseCorrelate's response (confidence) for this alignment.
  final double phaseCorr;
  /// Normalised cross-correlation between the two images' Canny edge maps -
  /// the edge/line-structure signal.
  final double edge;
  /// Block-matching dense-flow-consistency proxy: how uniform the local
  /// residual displacement is across the overlap region once the global
  /// candidate shift is applied - low, consistent residual flow indicates a
  /// genuine structural alignment rather than a coincidental global
  /// correlation peak.
  final double flow;
}

/// Scans every possible horizontal (yaw) alignment of [template]'s
/// cylindrical image against [refGray] (either a composite built by
/// [_compositeForScoring], or a single neighbour's own cylindrical image
/// used directly for the loop-closing check), returning the top scored
/// distinct local maxima together with several independent alignment
/// signals for each - not just a single correlation number, and not just a
/// feature correspondence. [refCoverage] marks which pixels of [refGray]
/// hold real content (a float32 weight map, >0 = covered, from
/// [_compositeForScoring]; or a plain 0/255 mask for the single-neighbour
/// case). [refWorldXAtCol0] is the world x-coordinate column 0 of [refGray]
/// corresponds to (see [_compositeForScoring]).
List<_YawSignal> _searchYaw(
  _Frame template,
  cv.Mat refGray,
  cv.Mat refCoverage,
  double refWorldXAtCol0,
  double f,
) {
  final templGray = cv.cvtColor(template.image, cv.COLOR_BGR2GRAY);
  final tw = templGray.cols, th = templGray.rows;
  if (refGray.rows < th) {
    templGray.dispose();
    return const [];
  }

  // Two adjacent captures typically only overlap over part of their width,
  // not the whole frame (a 60°-FOV shot 45° from its neighbour shares only
  // about a quarter of its width). Correlating the *entire* template at once
  // dilutes a real match with the majority of the frame that has nothing to
  // do with this particular neighbour, so the search itself runs over
  // several edge-focused sub-windows of the template - the regions actually
  // likely to hold the true overlap - as well as the full frame, and merges
  // whatever each finds. Still an exhaustive search over every possible yaw
  // (item 3/5), just scored at a scale that matches how these images
  // actually overlap.
  final edgeWidth = math.max(60, (tw * 0.35).round());
  final windows = <(int offset, int width)>{
    (0, tw),
    if (edgeWidth < tw) (0, edgeWidth),
    if (edgeWidth < tw) (tw - edgeWidth, edgeWidth),
  }.where((w) => w.$2 <= refGray.cols).toList();
  if (windows.isEmpty) {
    templGray.dispose();
    return const [];
  }

  // Candidate positions are tracked as "where in refGray would this
  // template's own local x=0 land" - a common coordinate space every
  // window's peaks convert into, so a left-edge-window peak and a
  // right-edge-window peak referring to the same true alignment merge into
  // one candidate instead of being reported twice.
  final candidateScore = <int, double>{};
  final candidateY = <int, int>{};
  // Which window (offset, width) within the template actually produced each
  // candidate's peak - the genuinely-overlapping sub-region, used below to
  // scope every other signal to the same area instead of diluting them
  // against the template's full (mostly non-overlapping) width again.
  final candidateWindow = <int, (int, int)>{};
  for (final (offset, width) in windows) {
    final sub = cv.Mat.fromMat(templGray, roi: cv.Rect(offset, 0, width, th), copy: true);
    final result = cv.matchTemplate(refGray, sub, cv.TM_CCOEFF_NORMED);
    sub.dispose();
    final rw = result.cols, rh = result.rows;
    final resultBytes = result.data;
    final resultF = resultBytes.buffer.asFloat32List(resultBytes.offsetInBytes, rw * rh);

    // Collapse to a 1D profile over x (best score at any y) - rotation-only
    // capture means the true alignment should sit at y≈0 regardless, so
    // scanning every y just finds it; a large winning y is itself a sign a
    // candidate isn't a real match.
    final profile = Float32List(rw);
    final profileY = Int32List(rw);
    for (var x = 0; x < rw; x++) {
      var best = -2.0, bestY = 0;
      for (var y = 0; y < rh; y++) {
        final v = resultF[y * rw + x];
        if (v > best) {
          best = v;
          bestY = y;
        }
      }
      profile[x] = best;
      profileY[x] = bestY;
    }

    final nmsWindow = math.max(10, width ~/ 3);
    for (var x = 0; x < rw; x++) {
      if (profile[x] < PanoramaStitcher._yawSearchMinPeakScore) continue;
      var isPeak = true;
      for (var k = math.max(0, x - nmsWindow); k <= math.min(rw - 1, x + nmsWindow); k++) {
        if (profile[k] > profile[x]) {
          isPeak = false;
          break;
        }
      }
      if (!isPeak) continue;
      final template0 = x - offset;
      var merged = false;
      for (final key in candidateScore.keys.toList()) {
        if ((key - template0).abs() > nmsWindow) continue;
        merged = true;
        if (profile[x] > candidateScore[key]!) {
          candidateScore.remove(key);
          candidateY.remove(key);
          candidateWindow.remove(key);
          candidateScore[template0] = profile[x];
          candidateY[template0] = profileY[x];
          candidateWindow[template0] = (offset, width);
        }
        break;
      }
      if (!merged) {
        candidateScore[template0] = profile[x];
        candidateY[template0] = profileY[x];
        candidateWindow[template0] = (offset, width);
      }
    }
    result.dispose();
  }

  final ranked = candidateScore.keys.toList()
    ..sort((a, b) => candidateScore[b]!.compareTo(candidateScore[a]!));
  final topPeaks = ranked.take(PanoramaStitcher._yawSearchCandidatesPerImage).toList();

  final coverageBytes = refCoverage.data;
  final coverageIsFloat = refCoverage.type == cv.MatType.CV_32FC1;
  final coverageF = coverageIsFloat
      ? coverageBytes.buffer.asFloat32List(coverageBytes.offsetInBytes, refGray.cols * refGray.rows)
      : null;
  final coverageU8 = coverageIsFloat
      ? null
      : coverageBytes.buffer.asUint8List(coverageBytes.offsetInBytes, refGray.cols * refGray.rows);
  bool covered(int idx) => coverageIsFloat ? coverageF![idx] > 0 : coverageU8![idx] > 0;

  final out = <_YawSignal>[];
  for (final xPeak0 in topPeaks) {
    final yPeak = candidateY[xPeak0]!;
    final (winOffset, winWidth) = candidateWindow[xPeak0]!;

    // The genuine overlap rectangle - the *winning window's* bounds shifted
    // to this candidate position, clipped to what refGray actually covers -
    // not the full template width, which for a typically-partial overlap
    // would dilute every signal below with a majority of non-overlapping
    // content (the same problem the windowed search above avoids for peak
    // detection itself).
    final refX0 = math.max(0, xPeak0 + winOffset);
    final refX1 = math.min(refGray.cols, xPeak0 + winOffset + winWidth);
    final refY0 = math.max(0, yPeak), refY1 = math.min(refGray.rows, yPeak + th);
    final ow = refX1 - refX0, oh = refY1 - refY0;
    if (ow < 40 || oh < 40) continue;
    final tX0 = refX0 - xPeak0, tY0 = refY0 - yPeak;

    var coveredPx = 0, sampled = 0;
    for (var y = 0; y < oh; y += 4) {
      for (var x = 0; x < ow; x += 4) {
        sampled++;
        if (covered((refY0 + y) * refGray.cols + (refX0 + x))) coveredPx++;
      }
    }
    // Normalised by the template's *full* area, not just the intersection,
    // so this reads as "how much of the candidate image overlaps existing
    // content", matching what item 12 asks the diagnostic to report.
    final overlapFraction = sampled == 0 ? 0.0 : coveredPx * (ow * oh / sampled) / (tw * th);
    if (overlapFraction < PanoramaStitcher._yawSearchMinOverlapFraction) continue;

    final templCrop = cv.Mat.fromMat(templGray, roi: cv.Rect(tX0, tY0, ow, oh), copy: true);
    final refCrop = cv.Mat.fromMat(refGray, roi: cv.Rect(refX0, refY0, ow, oh), copy: true);

    final templF = templCrop.convertTo(cv.MatType.CV_32FC1);
    final refF = refCrop.convertTo(cv.MatType.CV_32FC1);
    // phaseCorrelate needs a Hanning window to get a reliable response - the
    // border discontinuity of an unwindowed crop otherwise dominates the
    // phase spectrum and swamps genuine alignment signal (no binding for
    // OpenCV's own createHanningWindow is available, so built by hand).
    final hann = _hanningWindow(ow, oh);
    final (shift, response) = cv.phaseCorrelate(templF, refF, window: hann);
    hann.dispose();
    final phaseScore = response.isFinite ? response.clamp(0.0, 1.0) : 0.0;

    final edgeScore = _edgeCorrelationScore(templCrop, refCrop);
    final flowScore = _flowConsistencyScore(templCrop, refCrop);

    // Sub-pixel refinement of the integer matchTemplate peak using the
    // phase-correlation residual shift.
    final angleDeg =
        -(xPeak0 + refWorldXAtCol0) * 180 / (f * math.pi) - shift.x * 180 / (f * math.pi);

    out.add(_YawSignal(
      angleDeg: angleDeg,
      overlapFraction: overlapFraction.clamp(0.0, 1.0),
      photometric: ((candidateScore[xPeak0]! + 1) / 2).clamp(0.0, 1.0),
      phaseCorr: phaseScore,
      edge: edgeScore,
      flow: flowScore,
    ));

    for (final mat in [templCrop, refCrop, templF, refF]) {
      mat.dispose();
    }
  }
  templGray.dispose();
  return out;
}

/// A separable 2D Hanning window (no binding for OpenCV's own
/// createHanningWindow is available), needed so [cv.phaseCorrelate] isn't
/// dominated by the crop's own border discontinuity.
cv.Mat _hanningWindow(int cols, int rows) {
  final data = Float32List(cols * rows);
  for (var y = 0; y < rows; y++) {
    final wy = rows > 1 ? 0.5 * (1 - math.cos(2 * math.pi * y / (rows - 1))) : 1.0;
    for (var x = 0; x < cols; x++) {
      final wx = cols > 1 ? 0.5 * (1 - math.cos(2 * math.pi * x / (cols - 1))) : 1.0;
      data[y * cols + x] = wx * wy;
    }
  }
  return cv.Mat.fromList(rows, cols, cv.MatType.CV_32FC1, data);
}

/// Canny with thresholds derived from the image's own gradient strength
/// (a fixed absolute threshold finds nothing at all on a softened/blurred
/// image - exactly the kind of image that reaches this recovery stage -
/// while still being meaningful on a normal sharp one).
cv.Mat _autoCanny(cv.Mat gray) {
  final gx = cv.sobel(gray, cv.MatType.CV_32FC1.value, 1, 0);
  final gy = cv.sobel(gray, cv.MatType.CV_32FC1.value, 0, 1);
  final mag = cv.magnitude(gx, gy);
  final (meanS, _) = cv.meanStdDev(mag);
  gx.dispose();
  gy.dispose();
  mag.dispose();
  final low = math.max(4.0, meanS.val1 * 0.5);
  final high = math.max(low + 4, meanS.val1 * 1.5);
  return cv.canny(gray, low, high);
}

/// Normalised cross-correlation between the two images' Canny edge maps -
/// the "edge/line structure" alignment signal, for two already-cropped,
/// equal-sized grayscale regions.
double _edgeCorrelationScore(cv.Mat grayCropA, cv.Mat grayCropB) {
  final edgesA = _autoCanny(grayCropA);
  final edgesB = _autoCanny(grayCropB);
  var score = 0.5;
  if (edgesA.cols == edgesB.cols && edgesA.rows == edgesB.rows && edgesA.cols > 0 && edgesA.rows > 0) {
    final result = cv.matchTemplate(edgesA, edgesB, cv.TM_CCOEFF_NORMED);
    final data = result.data;
    final v = data.buffer.asFloat32List(data.offsetInBytes, 1)[0];
    if (v.isFinite) score = ((v + 1) / 2).clamp(0.0, 1.0);
    result.dispose();
  }
  edgesA.dispose();
  edgesB.dispose();
  return score;
}

/// Dense-flow-consistency proxy: splits the (already globally aligned)
/// overlap region into a grid of blocks and, for each, finds its best local
/// match in a small search window via matchTemplate (classic block-matching
/// optical flow) - a genuine structural alignment should leave these local
/// residual shifts small and mutually consistent, unlike a coincidental
/// global correlation peak. Returns 0.5 (uninformative) when the region is
/// too small or too textureless to judge.
double _flowConsistencyScore(cv.Mat grayCropA, cv.Mat grayCropB) {
  final w = grayCropA.cols, h = grayCropA.rows;
  const cols = 6, rows = 4;
  const searchX = 6, searchY = 4;
  final bw = w ~/ cols, bh = h ~/ rows;
  if (bw < 12 || bh < 12) return 0.5;

  final dxs = <double>[], dys = <double>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final bx = c * bw, by = r * bh;
      final patch = cv.Mat.fromMat(grayCropA, roi: cv.Rect(bx, by, bw, bh), copy: true);
      final winX = math.max(0, bx - searchX);
      final winY = math.max(0, by - searchY);
      final winW = math.min(w - winX, bw + 2 * searchX);
      final winH = math.min(h - winY, bh + 2 * searchY);
      if (winW >= bw && winH >= bh) {
        final window = cv.Mat.fromMat(grayCropB, roi: cv.Rect(winX, winY, winW, winH), copy: true);
        final res = cv.matchTemplate(window, patch, cv.TM_CCOEFF_NORMED);
        final rw = res.cols, rh = res.rows;
        final data = res.data.buffer.asFloat32List(res.data.offsetInBytes, rw * rh);
        var bestV = -2.0, bestX = 0, bestY = 0;
        for (var y = 0; y < rh; y++) {
          for (var x = 0; x < rw; x++) {
            final v = data[y * rw + x];
            if (v > bestV) {
              bestV = v;
              bestX = x;
              bestY = y;
            }
          }
        }
        if (bestV.isFinite && bestV > 0.2) {
          dxs.add((winX + bestX - bx).toDouble());
          dys.add((winY + bestY - by).toDouble());
        }
        res.dispose();
        window.dispose();
      }
      patch.dispose();
    }
  }
  if (dxs.length < 4) return 0.3;

  final meanDx = dxs.reduce((a, b) => a + b) / dxs.length;
  final meanDy = dys.reduce((a, b) => a + b) / dys.length;
  var varSum = 0.0;
  for (var i = 0; i < dxs.length; i++) {
    final ddx = dxs[i] - meanDx, ddy = dys[i] - meanDy;
    varSum += ddx * ddx + ddy * ddy;
  }
  final spread = math.sqrt(varSum / dxs.length);
  return (1.0 - spread / 6.0).clamp(0.0, 1.0);
}

/// Formats one yaw-search candidate's full diagnostic line - candidate
/// angle, overlap, feature inliers, every photometric/geometric signal, the
/// combined score, which placed images it was scored against, and its
/// outcome (item 12).
String _yawCandidateLine(
  _YawSignal s,
  int featureInliers,
  List<int> support,
  double combined,
  bool accepted,
  String? rejectReason,
) {
  final supportStr = support.isEmpty ? 'none' : support.map((i) => i + 1).join(',');
  final tag = accepted ? 'ACCEPTED' : (rejectReason ?? 'below acceptance bar');
  return 'yaw=${s.angleDeg.toStringAsFixed(1)}° overlap=${(s.overlapFraction * 100).round()}% '
      'features=$featureInliers photometric(NCC)=${s.photometric.toStringAsFixed(2)} '
      'phaseCorr=${s.phaseCorr.toStringAsFixed(2)} edge=${s.edge.toStringAsFixed(2)} '
      'flowConsistency=${s.flow.toStringAsFixed(2)} combined=${combined.toStringAsFixed(2)} '
      'supportingImages=$supportStr [$tag]';
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
