const double triggerIntervalDegrees = 45.0;
const double maximumCaptureGapDegrees = triggerIntervalDegrees * 1.5;

class SweepUpdate {
  const SweepUpdate({
    required this.heading,
    required this.cumulativeRotation,
    required this.direction,
    this.triggerInterval,
    this.tooFast = false,
  });

  final double heading;
  final double cumulativeRotation;
  final String? direction;
  final int? triggerInterval;
  final bool tooFast;
}

class GyroSweepTracker {
  GyroSweepTracker({required double initialHeading})
    : _previousHeading = normalizeHeading(initialHeading);

  double _previousHeading;
  double _unwrappedHeading = 0;
  double _cumulativeRotation = 0;
  double _rotationSinceCapture = 0;
  int? _directionSign;
  final Set<int> _capturedIntervals = <int>{};

  double get cumulativeRotation => _cumulativeRotation;
  String? get direction => _directionSign == null
      ? null
      : _directionSign! > 0
      ? 'Clockwise'
      : 'Counter-clockwise';
  Set<int> get capturedIntervals => Set.unmodifiable(_capturedIntervals);

  SweepUpdate update(double rawHeading) {
    final currentHeading = normalizeHeading(rawHeading);
    final delta = shortestSignedDelta(_previousHeading, currentHeading);
    _previousHeading = currentHeading;
    if (delta.abs() < 1.0) {
      return SweepUpdate(
        heading: currentHeading,
        cumulativeRotation: _cumulativeRotation,
        direction: direction,
      );
    }

    _directionSign ??= delta > 0 ? 1 : -1;
    final signedMovement = delta * _directionSign!;
    final previousUnwrapped = _unwrappedHeading;
    _unwrappedHeading += signedMovement;
    _cumulativeRotation += delta.abs();
    _rotationSinceCapture += delta.abs();

    if (_rotationSinceCapture > maximumCaptureGapDegrees) {
      return SweepUpdate(
        heading: currentHeading,
        cumulativeRotation: _cumulativeRotation,
        direction: direction,
        tooFast: true,
      );
    }

    final crossed = _crossedIntervals(previousUnwrapped, _unwrappedHeading);
    for (final interval in crossed) {
      if (_capturedIntervals.add(interval)) {
        _rotationSinceCapture = 0;
        return SweepUpdate(
          heading: currentHeading,
          cumulativeRotation: _cumulativeRotation,
          direction: direction,
          triggerInterval: interval,
        );
      }
    }

    return SweepUpdate(
      heading: currentHeading,
      cumulativeRotation: _cumulativeRotation,
      direction: direction,
    );
  }

  List<int> _crossedIntervals(double from, double to) {
    if (from == to) return const [];
    if (to > from) {
      final first = (from / triggerIntervalDegrees).floor() + 1;
      final last = (to / triggerIntervalDegrees).floor();
      return [
        for (var value = first; value <= last; value++) value,
      ].where((value) => value != 0).toList();
    }
    final first = (from / triggerIntervalDegrees).ceil() - 1;
    final last = (to / triggerIntervalDegrees).ceil();
    return [
      for (var value = first; value >= last; value--) value,
    ].where((value) => value != 0).toList();
  }

  static double normalizeHeading(double heading) => (heading % 360 + 360) % 360;

  static double shortestSignedDelta(double from, double to) {
    final delta = (to - from + 540) % 360 - 180;
    return delta == -180 ? 180 : delta;
  }
}

double normalizeHeading(double heading) =>
    GyroSweepTracker.normalizeHeading(heading);
double shortestSignedDelta(double from, double to) =>
    GyroSweepTracker.shortestSignedDelta(from, to);
