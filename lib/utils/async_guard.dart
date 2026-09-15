/// Leading-edge in-flight lock for async UI actions.
///
/// First call runs; overlapping calls return `null` until the first finishes.
/// Prefer this over time-based debounce so legitimate later taps still work.
class AsyncGuard {
  bool _locked = false;

  bool get isLocked => _locked;

  Future<T?> run<T>(Future<T> Function() action) async {
    if (_locked) return null;
    _locked = true;
    try {
      return await action();
    } finally {
      _locked = false;
    }
  }

  Future<void> runVoid(Future<void> Function() action) async {
    await run(() async {
      await action();
      return true;
    });
  }
}
