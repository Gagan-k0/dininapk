import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/utils/menu_page_window.dart';
import 'package:dineinapk/widgets/pos_category_rail.dart';

void main() {
  group('MenuPageWindow', () {
    test('resets to first page and loads more', () {
      final page = MenuPageWindow<int>(pageSize: 3);
      page.reset(List.generate(10, (i) => i));
      expect(page.visible, [0, 1, 2]);
      expect(page.hasMore, isTrue);
      expect(page.loadMore(), isTrue);
      expect(page.visible, [0, 1, 2, 3, 4, 5]);
      page.loadMore();
      page.loadMore();
      expect(page.visible.length, 10);
      expect(page.hasMore, isFalse);
      expect(page.loadMore(), isFalse);
    });

    test('empty source stays empty', () {
      final page = MenuPageWindow<String>(pageSize: 5);
      page.reset(const []);
      expect(page.visible, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });

  testWidgets('PosCategoryRail shows ALL and category names vertically', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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
              onSelect: (id) => selected = id,
            ),
          ),
        ),
      ),
    );

    expect(find.text('ALL'), findsOneWidget);
    expect(find.text('STARTERS'), findsOneWidget);
    expect(find.text('MAINS'), findsOneWidget);

    await tester.tap(find.text('STARTERS'));
    await tester.pumpAndSettle();
    expect(selected, 'c1');
  });
}
