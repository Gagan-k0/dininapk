import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/utils/extra_addons.dart';

void main() {
  test('mapExtraAddonCards flattens values and prepends + Custom', () {
    final cards = mapExtraAddonCards([
      {
        'value': [
          {'status': 1, 'valuename': 'Butter', 'price': '10', '_id': 'a1'},
          {'status': 0, 'valuename': 'Inactive', 'price': '5', '_id': 'a0'},
          {'status': 1, 'valuename': 'Extra Paneer', 'price': '40', '_id': 'a2'},
        ],
      },
    ]);

    expect(cards.first.isCustomAddonTrigger, isTrue);
    expect(cards.first.label, '+ Custom');
    expect(cards.where((c) => c.isExtraAddon).map((c) => c.label).toList(), [
      'Butter',
      'Extra Paneer',
    ]);
  });

  test('mapExtraAddonCards search filters by name', () {
    final cards = mapExtraAddonCards(
      [
        {
          'value': [
            {'status': 1, 'valuename': 'Butter', 'price': '10'},
            {'status': 1, 'valuename': 'Cheese', 'price': '20'},
          ],
        },
      ],
      search: 'chee',
    );
    expect(cards.length, 2); // + Custom + Cheese
    expect(cards.last.label, 'Cheese');
  });

  test('MenuItem parses is_favorite from API', () {
    final item = MenuItem.fromJson({
      '_id': 'm1',
      'displayname': 'Idli',
      'price': 40,
      'is_favorite': true,
    });
    expect(item.isFavorite, isTrue);
  });
}
