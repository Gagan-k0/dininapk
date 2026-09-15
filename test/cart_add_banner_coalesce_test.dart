import 'package:flutter_test/flutter_test.dart';

/// Mirrors [_FoodCategoriesScreenState._coalesceAddMessage] for unit coverage.
String coalesceCartAddMessage(List<({String name, int qty})> deltas) {
  final totalQty = deltas.fold<int>(0, (sum, d) => sum + d.qty);
  if (totalQty <= 0) return 'Added';
  final names = {for (final d in deltas) d.name};
  if (totalQty == 1) return 'Added ${deltas.first.name}';
  if (names.length == 1) return 'Added ${names.first} ×$totalQty';
  return 'Added $totalQty items';
}

void main() {
  test('coalesce single add', () {
    expect(
      coalesceCartAddMessage([(name: 'Tea', qty: 1)]),
      'Added Tea',
    );
  });

  test('coalesce same item multi tap', () {
    expect(
      coalesceCartAddMessage([
        (name: 'Tea', qty: 1),
        (name: 'Tea', qty: 1),
        (name: 'Tea', qty: 1),
      ]),
      'Added Tea ×3',
    );
  });

  test('coalesce mixed items', () {
    expect(
      coalesceCartAddMessage([
        (name: 'Tea', qty: 2),
        (name: 'Coffee', qty: 1),
      ]),
      'Added 3 items',
    );
  });
}
