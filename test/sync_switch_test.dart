import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/auth_service.dart';
import 'package:dineinapk/services/connectivity_service.dart';
import 'package:dineinapk/widgets/sync_status_chip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final net = ConnectivityService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await net.load();
    net.clearSignal();
    await AuthService().saveSession(token: 'tok', restaurantId: 'r1');
  });

  var sent = 0;
  ApiClient client(Future<http.Response> Function() answer) => ApiClient(
    auth: AuthService(),
    httpClient: MockClient((_) async {
      sent++;
      return answer();
    }),
  );

  test('Sync off: no request leaves the tablet', () async {
    sent = 0;
    await net.setSyncOn(false);
    await expectLater(
      client(() async => http.Response('{}', 200)).get('/x'),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true)),
    );
    expect(sent, 0);
    expect(net.state, SyncState.offlineManual);
  });

  test('Sync off still lets a signed-out waiter log in', () async {
    sent = 0;
    await net.setSyncOn(false);
    await AuthService().logout();
    await client(
      () async => http.Response('{"status":{"code":200},"data":{}}', 200),
    ).post('/login');
    expect(sent, 1);
  });

  test('the switch survives an app restart', () async {
    await net.setSyncOn(false);
    await net.setSyncOn(true);
    await net.setSyncOn(false);
    await net.load();
    expect(net.syncOff, isTrue);
  });

  test('a transport failure flips to No signal, any answer flips back', () async {
    await net.setSyncOn(true);
    await expectLater(
      client(() async => throw const SocketException('down')).get('/x'),
      throwsA(isA<ApiException>()),
    );
    expect(net.state, SyncState.offlineNoSignal);

    // Even a refusal proves the server is reachable.
    await expectLater(
      client(
        () async =>
            http.Response('{"status":{"code":422,"message":"no"}}', 200),
      ).get('/x'),
      throwsA(isA<ApiException>()),
    );
    expect(net.state, SyncState.online);
  });

  test('menu age label', () {
    final now = DateTime(2026, 9, 17, 12);
    expect(SyncStatusChip.ago(now, now), 'just now');
    expect(SyncStatusChip.ago(now.subtract(const Duration(minutes: 5)), now), '5m ago');
    expect(SyncStatusChip.ago(now.subtract(const Duration(hours: 3)), now), '3h ago');
    expect(SyncStatusChip.ago(now.subtract(const Duration(days: 2)), now), '2d ago');
  });

  testWidgets('chip toggles Sync from its sheet', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => net.setSyncOn(true));
    var synced = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [SyncStatusChip(onSyncMenu: () => synced++)],
          ),
        ),
      ),
    );
    expect(find.text('Online'), findsOneWidget);

    await tester.tap(find.text('Online'));
    await tester.pumpAndSettle();
    expect(find.text('Not downloaded yet'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(net.syncOff, isTrue);
    expect(find.text('Sync off'), findsOneWidget);

    // Sync menu is disabled while Sync is off.
    await tester.tap(find.text('Sync menu'));
    expect(synced, 0);
  });

  testWidgets('phones get an icon-only button', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => net.setSyncOn(true));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(appBar: AppBar(actions: const [SyncStatusChip()])),
      ),
    );
    expect(find.text('Online'), findsNothing);
    expect(find.byTooltip('Sync: Online'), findsOneWidget);
  });
}
