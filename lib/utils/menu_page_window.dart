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

  List<T> get visible =>
      _source.isEmpty ? const [] : _source.sublist(0, _visibleCount.clamp(0, _source.length));

  bool get hasMore => _visibleCount < _source.length;

  int get totalCount => _source.length;

  int get visibleCount => _visibleCount;

  /// Replace source (category / search change) and show the first page.
  void reset(List<T> source) {
    _source = List<T>.unmodifiable(source);
    _visibleCount = _source.isEmpty ? 0 : _source.length.clamp(0, pageSize);
  }

  /// Append the next page. Returns true if more items were revealed.
  bool loadMore() {
    if (!hasMore) return false;
    final next = (_visibleCount + pageSize).clamp(0, _source.length);
    if (next == _visibleCount) return false;
    _visibleCount = next;
    return true;
  }
}
