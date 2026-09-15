import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/views/settings/printer_settings_screen.dart';
import 'package:dineinapk/views/settings/receipt_preview.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: PrinterSettingsScreen()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('landscape: preview sits beside the form, visible without scrolling',
      (tester) async {
    await _pumpAt(tester, const Size(1280, 800));

    final preview = find.byType(ReceiptPreview);
    expect(preview, findsOneWidget);
    final previewLeft = tester.getTopLeft(preview).dx;
    final connectionLeft = tester.getTopLeft(find.text('Connection Type')).dx;
    expect(previewLeft, greaterThan(connectionLeft + 400));
    expect(tester.getTopLeft(preview).dy, lessThan(800));
  });

  testWidgets('portrait phone: preview stays stacked under the form', (tester) async {
    await _pumpAt(tester, const Size(400, 800));

    final preview = find.byType(ReceiptPreview);
    expect(preview, findsOneWidget);
    expect(
      tester.getTopLeft(preview).dx,
      moreOrLessEquals(tester.getTopLeft(find.text('Connection Type')).dx, epsilon: 1),
    );
  });
}
