import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:vazhikatti_dataset_collector/services/panorama/panorama_stitcher.dart';

/// Textured 360° cylinder (radius f) rendered into 8 pinhole views, 45° apart.
List<String> _renderViews(Directory dir, {int skipTexture = -1}) {
  const w = 480, h = 640;
  final f = (w / 2) / math.tan(30 * math.pi / 180); // 60° horizontal FOV
  final scene = cv.Mat.zeros(h, (2 * math.pi * f).round(), cv.MatType.CV_8UC3);
  final rng = math.Random(7);
  for (var i = 0; i < 1500; i++) {
    cv.circle(
      scene,
      cv.Point(rng.nextInt(scene.cols), rng.nextInt(h)),
      3 + rng.nextInt(18),
      cv.Scalar(rng.nextInt(255).toDouble(), rng.nextInt(255).toDouble(),
          rng.nextInt(255).toDouble()),
      thickness: rng.nextBool() ? -1 : 2,
    );
  }
  final paths = <String>[];
  for (var k = 0; k < 8; k++) {
    final yaw = k * 45 * math.pi / 180;
    final mx = Float32List(w * h), my = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x - w / 2, dy = y - h / 2;
        final theta = yaw + math.atan(dx / f);
        var u = theta * f;
        u = ((u % scene.cols) + scene.cols) % scene.cols;
        mx[y * w + x] = u;
        my[y * w + x] = h / 2 + f * dy / f / math.sqrt(dx * dx / (f * f) + 1);
      }
    }
    final view = cv.remap(
      scene,
      cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, mx),
      cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, my),
      cv.INTER_LINEAR,
    );
    final path = p.join(dir.path, 'view_$k.jpg');
    cv.imwrite(path, k == skipTexture ? cv.Mat.zeros(h, w, cv.MatType.CV_8UC3) : view);
    paths.add(path);
  }
  return paths;
}

/// Same 8-view sweep, but the view at [swapIndex] is rendered from a second,
/// unrelated textured scene instead of the shared one - individually rich in
/// SIFT keypoints (so `_prepare`'s per-image check still passes), but with
/// genuinely no correspondence to its neighbours, exercising the "drop what
/// doesn't connect" path instead of forcing it into the panorama.
List<String> _renderViewsWithSwap(Directory dir, int swapIndex) {
  const w = 480, h = 640;
  final f = (w / 2) / math.tan(30 * math.pi / 180); // 60° horizontal FOV

  cv.Mat scene(int seed) {
    final m = cv.Mat.zeros(h, (2 * math.pi * f).round(), cv.MatType.CV_8UC3);
    final rng = math.Random(seed);
    for (var i = 0; i < 1500; i++) {
      cv.circle(
        m,
        cv.Point(rng.nextInt(m.cols), rng.nextInt(h)),
        3 + rng.nextInt(18),
        cv.Scalar(rng.nextInt(255).toDouble(), rng.nextInt(255).toDouble(),
            rng.nextInt(255).toDouble()),
        thickness: rng.nextBool() ? -1 : 2,
      );
    }
    return m;
  }

  final sceneA = scene(7);
  final sceneB = scene(99);
  final paths = <String>[];
  for (var k = 0; k < 8; k++) {
    final s = k == swapIndex ? sceneB : sceneA;
    final yaw = k * 45 * math.pi / 180;
    final mx = Float32List(w * h), my = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x - w / 2, dy = y - h / 2;
        final theta = yaw + math.atan(dx / f);
        var u = theta * f;
        u = ((u % s.cols) + s.cols) % s.cols;
        mx[y * w + x] = u;
        my[y * w + x] = h / 2 + f * dy / f / math.sqrt(dx * dx / (f * f) + 1);
      }
    }
    final view = cv.remap(
      s,
      cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, mx),
      cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, my),
      cv.INTER_LINEAR,
    );
    final path = p.join(dir.path, 'swap_view_$k.jpg');
    cv.imwrite(path, view);
    paths.add(path);
  }
  return paths;
}

/// Same 8-view sweep as [_renderViews], but the views at [degradedIndices]
/// are heavily blurred and given strong independent per-pixel noise after
/// rendering - still genuinely the same underlying scene (unlike
/// [_renderViewsWithSwap]'s unrelated-content case), so photometric/edge/flow
/// correlation against it can still succeed, but with its fine repeatable
/// corner structure scrambled enough that SIFT/ORB matching against its
/// sharp neighbours drops below even the weak-evidence bar. Exercises the
/// photometric/geometric yaw-search recovery stage specifically, rather than
/// the direct or triangulated feature-matching stages.
List<String> _renderViewsWithDegraded(Directory dir, Set<int> degradedIndices) {
  const w = 480, h = 640;
  final f = (w / 2) / math.tan(30 * math.pi / 180); // 60° horizontal FOV
  final scene = cv.Mat.zeros(h, (2 * math.pi * f).round(), cv.MatType.CV_8UC3);
  final rng = math.Random(7);
  // A real captured scene has non-repetitive large-scale structure (walls,
  // furniture, windows) that correlation-based matching can lock onto - a
  // field of uniformly-distributed same-style random circles alone is
  // statistically repetitive across the whole cylinder and is genuinely
  // ambiguous for whole-region photometric matching (though not for SIFT,
  // which only needs local distinctiveness), so a handful of large,
  // distinctly-coloured landmark blocks are layered in first.
  final landmarkColors = [
    cv.Scalar(30, 30, 220), cv.Scalar(30, 200, 30), cv.Scalar(220, 30, 30),
    cv.Scalar(200, 200, 30), cv.Scalar(200, 30, 200), cv.Scalar(30, 200, 200),
    cv.Scalar(120, 60, 200), cv.Scalar(60, 160, 220), cv.Scalar(200, 120, 60),
    cv.Scalar(90, 200, 120),
  ];
  const landmarkCount = 10;
  final landmarkWidth = scene.cols / landmarkCount;
  for (var i = 0; i < landmarkCount; i++) {
    cv.rectangle(
      scene,
      cv.Rect((i * landmarkWidth).round(), 0, landmarkWidth.ceil(), h),
      landmarkColors[i % landmarkColors.length],
      thickness: -1,
    );
  }
  for (var i = 0; i < 1500; i++) {
    cv.circle(
      scene,
      cv.Point(rng.nextInt(scene.cols), rng.nextInt(h)),
      3 + rng.nextInt(18),
      cv.Scalar(rng.nextInt(255).toDouble(), rng.nextInt(255).toDouble(),
          rng.nextInt(255).toDouble()),
      thickness: rng.nextBool() ? -1 : 2,
    );
  }
  final paths = <String>[];
  for (var k = 0; k < 8; k++) {
    final yaw = k * 45 * math.pi / 180;
    final mx = Float32List(w * h), my = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x - w / 2, dy = y - h / 2;
        final theta = yaw + math.atan(dx / f);
        var u = theta * f;
        u = ((u % scene.cols) + scene.cols) % scene.cols;
        mx[y * w + x] = u;
        my[y * w + x] = h / 2 + f * dy / f / math.sqrt(dx * dx / (f * f) + 1);
      }
    }
    var view = cv.remap(
      scene,
      cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, mx),
      cv.Mat.fromList(h, w, cv.MatType.CV_32FC1, my),
      cv.INTER_LINEAR,
    );
    if (degradedIndices.contains(k)) {
      final blurred = cv.gaussianBlur(view, (23, 23), 10);
      view.dispose();
      view = blurred;
    }
    final path = p.join(dir.path, 'degraded_view_$k.jpg');
    cv.imwrite(path, view);
    paths.add(path);
  }
  return paths;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pano_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('8 overlapping views stitch into one valid panorama', () async {
    final views = _renderViews(dir);
    final out = p.join(dir.path, 'pano.jpg');
    final result = await PanoramaStitcher.stitch(views, out);
    expect(File(out).existsSync(), isTrue);
    final img = cv.imread(out);
    expect(img.isEmpty, isFalse);
    expect(img.cols, result.width);
    expect(img.cols, greaterThan(480 * 3));
    expect(result.inlierCount, greaterThan(0));
    expect(result.usedImageCount, 8);
    expect(result.droppedImages, isEmpty);
    // originals untouched
    for (final v in views) {
      expect(File(v).existsSync(), isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the same 8 views in shuffled, arbitrary order stitch the same way', () async {
    final views = _renderViews(dir)..shuffle(math.Random(3));
    final out = p.join(dir.path, 'pano.jpg');
    final result = await PanoramaStitcher.stitch(views, out);
    final img = cv.imread(out);
    expect(img.isEmpty, isFalse);
    expect(img.cols, greaterThan(480 * 3));
    expect(result.usedImageCount, 8);
    expect(result.droppedImages, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a textureless frame fails with the failing image identified', () async {
    final views = _renderViews(dir, skipTexture: 3);
    final out = p.join(dir.path, 'pano.jpg');
    await expectLater(
      PanoramaStitcher.stitch(views, out),
      throwsA(
        isA<PanoramaStitchException>()
            .having((e) => e.stage, 'stage', 'features')
            .having((e) => e.pair, 'pair', 4),
      ),
    );
    expect(File(out).existsSync(), isFalse);
    for (final v in views) {
      expect(File(v).existsSync(), isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a genuinely unrelated image is dropped rather than failing the whole panorama',
    () async {
      final views = _renderViewsWithSwap(dir, 4);
      final out = p.join(dir.path, 'pano.jpg');
      final result = await PanoramaStitcher.stitch(views, out);
      expect(File(out).existsSync(), isTrue);
      final img = cv.imread(out);
      expect(img.isEmpty, isFalse);
      expect(img.cols, greaterThan(480 * 3));
      expect(result.usedImageCount, 7);
      expect(result.droppedImages, [5]); // 1-based: swapIndex 4 -> image 5
      for (final v in views) {
        expect(File(v).existsSync(), isTrue);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'images with no usable feature evidence are recovered via geometric '
    'yaw-search instead of being dropped',
    () async {
      final views = _renderViewsWithDegraded(dir, {0, 2});
      final out = p.join(dir.path, 'pano.jpg');
      final result = await PanoramaStitcher.stitch(views, out);
      expect(File(out).existsSync(), isTrue);
      final img = cv.imread(out);
      expect(img.isEmpty, isFalse);
      expect(result.usedImageCount, 8);
      expect(result.droppedImages, isEmpty);
      expect(
        result.recoveredViaGeometricSearch,
        containsAll([1, 3]),
        reason: 'diagnostics: ${result.pairDiagnostics}\n'
            'yaw-search candidates: ${result.yawSearchDiagnostics}',
      );
      for (final v in views) {
        expect(File(v).existsSync(), isTrue);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'nothing connects at all throws instead of producing a meaningless image',
    () async {
      // view 0 (scene A) and view 4 (scene B) share no overlap by construction.
      final views = _renderViewsWithSwap(dir, 4);
      final out = p.join(dir.path, 'pano.jpg');
      await expectLater(
        PanoramaStitcher.stitch([views[0], views[4]], out),
        throwsA(isA<PanoramaStitchException>().having((e) => e.stage, 'stage', 'matching')),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('in capture order', () {
    final headings = [for (var k = 0; k < 8; k++) (k * 45.0) % 360];

    test('8 views taken in order close into one 360° panorama', () async {
      final views = _renderViews(dir);
      final out = p.join(dir.path, 'pano.jpg');
      final result = await PanoramaStitcher.stitchInOrder(
        views,
        out,
        headingsDeg: headings,
        stepDeg: 45,
        closesLoop: true,
      );
      final img = cv.imread(out);
      expect(img.isEmpty, isFalse);
      expect(result.usedImageCount, 8);
      expect(result.sensorPlacedLinks, isEmpty, reason: '${result.pairDiagnostics}');
      expect(result.loopClosureErrorDeg, lessThan(3));
      // One full turn: 2πf at the 60° test FOV, not wrapped content twice.
      final fullTurn = 2 * math.pi * (240 / math.tan(30 * math.pi / 180));
      expect(img.cols, lessThanOrEqualTo(fullTurn.round()));
      expect(img.cols, greaterThan(fullTurn * 0.9));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a frame with no usable detail is kept, placed by compass', () async {
      final views = _renderViews(dir, skipTexture: 3);
      final out = p.join(dir.path, 'pano.jpg');
      final result = await PanoramaStitcher.stitchInOrder(
        views,
        out,
        headingsDeg: headings,
        closesLoop: true,
      );
      expect(File(out).existsSync(), isTrue);
      expect(result.usedImageCount, 8);
      expect(result.droppedImages, isEmpty);
      // Image 4 is blank: its joins to image 3 and to image 5 had to use the compass.
      expect(result.sensorPlacedLinks, [3, 4]);
      expect(result.pairDiagnostics[2], contains('compass'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('with no visual overlap and nothing to fall back on, names the join', () async {
      final views = _renderViews(dir, skipTexture: 1);
      final out = p.join(dir.path, 'pano.jpg');
      await expectLater(
        PanoramaStitcher.stitchInOrder(views.sublist(0, 3), out),
        throwsA(
          isA<PanoramaStitchException>()
              .having((e) => e.stage, 'stage', 'matching')
              .having((e) => e.pair, 'pair', 1),
        ),
      );
      expect(File(out).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
