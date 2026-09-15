/// Client-side window over a filtered menu list (admin-style infinite scroll).
///
/// Flutter [GridView.builder] already virtualizes paint; this window limits how
/// many logical rows we expose while scrolling so very large menus stay snappy
/// when filters change (reset window) and grow as the user nears the bottom.
class MenuPageWindow<T> {
  MenuPageWindow({
    this.pageSize = 80,
  });

  final int pageSize;

  List<T> _source = const [];
  int _visibleCount = 0;
  String _fingerprint = '';
  bool _loadingMore = false;

  List<T> get visible => _source.isEmpty
      ? const []
      : _source.sublist(0, _visibleCount.clamp(0, _source.length));

  bool get hasMore => _visibleCount < _source.length;

  int get totalCount => _source.length;

  int get visibleCount => _visibleCount;

  String get fingerprint => _fingerprint;

  /// Sync source to [fingerprint]. Returns true when the visible window changed.
  bool reset(List<T> source, {required String fingerprint}) {
    final filterChanged = fingerprint != _fingerprint;
    if (!filterChanged && source.length == _source.length) {
      return false;
    }

    _fingerprint = fingerprint;
    _source = List<T>.unmodifiable(source);
    if (filterChanged || _visibleCount == 0) {
      _visibleCount =
          _source.isEmpty ? 0 : _source.length.clamp(0, pageSize);
    } else {
      _visibleCount = _visibleCount.clamp(
        0,
        _source.isEmpty ? 0 : _source.length,
      );
      if (_visibleCount == 0 && _source.isNotEmpty) {
        _visibleCount = _source.length.clamp(0, pageSize);
      }
    }
    _loadingMore = false;
    return true;
  }

  /// Append the next page. Returns true if more items were revealed.
  bool loadMore() {
    if (_loadingMore || !hasMore) return false;
    _loadingMore = true;
    final next = (_visibleCount + pageSize).clamp(0, _source.length);
    final grew = next > _visibleCount;
    _visibleCount = next;
    _loadingMore = false;
    return grew;
  }
}
