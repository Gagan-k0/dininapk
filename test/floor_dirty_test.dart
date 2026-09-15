import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/providers/pos_provider.dart';

void main() {
  test('consumeFloorDirty returns once then clears', () {
    final pos = PosProvider();
    expect(pos.consumeFloorDirty(), isFalse);
    pos.markFloorDirty();
    expect(pos.floorDirty, isTrue);
    expect(pos.consumeFloorDirty(), isTrue);
    expect(pos.consumeFloorDirty(), isFalse);
    pos.markFloorDirty();
    pos.clearFloorDirty();
    expect(pos.floorDirty, isFalse);
  });
}
