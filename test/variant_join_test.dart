import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/models/menu_model.dart';

void main() {
  test('MenuVariant.fromJson keeps blank name when API omits it', () {
    final v = MenuVariant.fromJson({
      'variant_id': 'vid1',
      'price': 120,
      'status': 1,
    });
    expect(v.id, 'vid1');
    expect(v.name, isEmpty);
    expect(v.price, 120);
  });

  test('MenuVariant can be rebuilt with catalog name', () {
    final raw = MenuVariant.fromJson({
      'variant_id': 'vid1',
      'price': 80,
    });
    final joined = MenuVariant(
      id: raw.id,
      name: raw.name.isNotEmpty ? raw.name : 'Half',
      price: raw.price,
    );
    expect(joined.name, 'Half');
  });
}
