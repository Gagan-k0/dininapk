import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/services/menu_cache_service.dart';
import 'package:dineinapk/utils/menu_page_window.dart';
import 'package:dineinapk/widgets/pos_category_rail.dart';

void main() {
  group('MenuPageWindow', () {
    test('resets to first page and loads more', () {
      final page = MenuPageWindow<int>(pageSize: 3);
      expect(page.reset(List.generate(10, (i) => i), fingerprint: 'all'), isTrue);
      expect(page.visible, [0, 1, 2]);
      expect(page.hasMore, isTrue);
      expect(page.loadMore(), isTrue);
      expect(page.visible, [0, 1, 2, 3, 4, 5]);
      page.loadMore();
      page.loadMore();
      expect(page.visible.length, 10);
      expect(page.hasMore, isFalse);
      expect(page.loadMore(), isFalse);
      // Same fingerprint does not wipe the window.
      expect(page.reset(List.generate(10, (i) => i), fingerprint: 'all'), isFalse);
      expect(page.visible.length, 10);
    });

    test('empty source stays empty', () {
      final page = MenuPageWindow<String>(pageSize: 5);
      page.reset(const [], fingerprint: 'empty');
      expect(page.visible, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });

  group('MenuCacheService', () {
    test('round-trips categories and items', () async {
      SharedPreferences.setMockInitialValues({});
      final cache = MenuCacheService();
      await cache.save(
        restaurantId: 'rest-1',
        categories: [
          {'_id': 'c1', 'displayname': 'Starters', 'valuename': 'starters'},
        ],
        items: [
          {
            '_id': 'm1',
            'name': 'Soup',
            'displayname': 'Soup',
            'attribute': 'VEG',
            'price': 50,
          },
        ],
      );

      final snap = await cache.load('rest-1');
      expect(snap, isNotNull);
      expect(snap!.categories.single.categoryName, 'Starters');
      expect(snap.items.single.label, 'Soup');
    });
  });

  testWidgets('PosCategoryRail shows ALL and collapses to initials', (
    tester,
  ) async {
    String? selected;
    var collapsed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: SizedBox(
                height: 400,
                child: PosCategoryRail(
                  categories: [
                    MenuCategory(
                      id: 'c1',
                      categoryName: 'Starters',
                      valueName: 'starters',
                    ),
                    MenuCategory(
                      id: 'c2',
                      categoryName: 'Mains',
                      valueName: 'mains',
                    ),
                  ],
                  selectedCategoryId: null,
                  collapsed: collapsed,
                  onToggleCollapsed: () =>
                      setState(() => collapsed = !collapsed),
                  onSelect: (id) => selected = id,
                ),
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('ALL'), findsOneWidget);
    expect(find.text('STARTERS'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse categories'));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget); // ALL initial
    expect(find.text('S'), findsOneWidget); // Starters

    await tester.tap(find.text('S'));
    await tester.pumpAndSettle();
    expect(selected, 'c1');
  });
}
