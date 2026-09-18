import 'package:flutter_test/flutter_test.dart';
import 'package:dineinapk/models/menu_model.dart';

void main() {
  test('getmenu stub addOns do not become Addon rows', () {
    final item = MenuItem.fromJson({
      '_id': 'm1',
      'name': 'Apple Milk Shake',
      'price': 90,
      'addOns': [
        {'_id': 'sub1', 'addon_id': 'cat1'},
      ],
    });
    expect(item.addons, isEmpty);
  });

  test('value[] options still parse with names and prices', () {
    final item = MenuItem.fromJson({
      '_id': 'm1',
      'name': 'Shake',
      'price': 90,
      'addOns': [
        {
          '_id': 'cat1',
          'displayname': 'Toppings',
          'value': [
            {
              '_id': 'v1',
              'valuename': 'Extra Scoop',
              'price': 20,
              'status': 1,
            },
          ],
        },
      ],
    });
    expect(item.addons.length, 1);
    expect(item.addons.first.valueName, 'Extra Scoop');
    expect(item.addons.first.price, 20);
  });
}
