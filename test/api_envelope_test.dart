import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/models/table_model.dart';
import 'package:dineinapk/providers/table_provider.dart';
import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/api_service.dart';
import 'package:dineinapk/services/auth_service.dart';
import 'package:dineinapk/services/bill_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AuthService().saveSession(
      token: 'test-token',
      restaurantId: 'rest-1',
    );
    ApiClient.onSessionExpired = null;
    ApiClient.sessionRefreshed();
  });

  ApiClient clientFor(http.Response Function(http.Request) handler) {
    return ApiClient(
      auth: AuthService(),
      httpClient: MockClient((request) async => handler(request)),
    );
  }

  test('HTTP 200 with envelope 422 throws the server message', () async {
    final client = clientFor(
      (_) => http.Response(
        jsonEncode({
          'status': {'code': 422, 'message': 'split_not_fully_paid'},
        }),
        200,
      ),
    );

    await expectLater(
      client.get('/refused'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 422)
            .having((e) => e.message, 'message', 'split_not_fully_paid'),
      ),
    );
  });

  test('HTTP 401 expires the session once', () async {
    var calls = 0;
    ApiClient.onSessionExpired = (_) => calls++;
    final client = clientFor(
      (_) => http.Response(
        jsonEncode({
          'status': {'code': 401, 'message': 'Invalid Token'},
        }),
        401,
      ),
    );

    for (var i = 0; i < 2; i++) {
      await expectLater(
        client.get('/expired'),
        throwsA(isA<ApiException>().having((e) => e.isAuth, 'isAuth', isTrue)),
      );
    }
    expect(calls, 1);
  });

  for (final code in [401, 2024]) {
    test('envelope $code expires the session once', () async {
      var calls = 0;
      ApiClient.onSessionExpired = (_) => calls++;
      final client = clientFor(
        (_) => http.Response(
          jsonEncode({
            'status': {'code': code, 'message': 'Session expired'},
          }),
          200,
        ),
      );

      await expectLater(
        client.get('/expired'),
        throwsA(isA<ApiException>().having((e) => e.isAuth, 'isAuth', isTrue)),
      );
      expect(calls, 1);
    });
  }

  test('background auth failure never logs the cashier out', () async {
    var calls = 0;
    ApiClient.onSessionExpired = (_) => calls++;
    final client = clientFor(
      (_) => http.Response(
        jsonEncode({
          'status': {'code': 2024, 'message': 'Session expired'},
        }),
        200,
      ),
    );

    await expectLater(
      client.get('/sync', background: true),
      throwsA(isA<ApiException>().having((e) => e.isAuth, 'isAuth', isTrue)),
    );
    expect(calls, 0);
  });

  test('successful envelope with no data key is an empty list', () async {
    final client = clientFor(
      (_) => http.Response(
        jsonEncode({
          'status': {'code': 200, 'message': 'ok'},
        }),
        200,
      ),
    );

    expect((await client.get('/empty')).list, isEmpty);
  });

  test('HTTP 200 with no valid status code is refused as malformed', () async {
    final client = clientFor((_) => http.Response('{"unexpected":true}', 200));

    await expectLater(
      client.get('/malformed'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', -1)
            .having(
              (e) => e.message,
              'message',
              'Malformed response from server',
            ),
      ),
    );
  });

  test('DineInTable maps cart id, seated time and release gate', () {
    final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final objectId =
        '${nowSeconds.toRadixString(16).padLeft(8, '0')}0000000000000000';
    final table = DineInTable.fromJson({
      '_id': 'table-1',
      'table_number': '10',
      'area_id': 'area-1',
      'table_status': 'PRINTED',
      'cart_details': {'_id': objectId, 'total_price': 219},
    });

    expect(table.cartId, objectId);
    expect(table.seatedMinutes, inInclusiveRange(0, 1));
    expect(table.canRelease, isTrue);
    expect(
      DineInTable.fromJson({'_id': 'table-2', 'table_status': 'KOT'})
          .canRelease,
      isFalse,
    );
  });

  test(
    'TableProvider keeps the last-known floor after refused refresh',
    () async {
      final api = _FakeApiService()
        ..areasResult = [TableArea(id: 'area-1', name: 'Main')]
        ..tablesResult = [_table('table-1')];
      final provider = TableProvider(api: api);
      await provider.loadDashboardData();
      expect(provider.tables, hasLength(1));

      api.floorError = const ApiException('refresh refused', code: 422);
      await provider.refresh();

      expect(provider.tables, hasLength(1));
      expect(provider.isStale, isTrue);
      expect(provider.errorMessage, 'refresh refused');
    },
  );

  test('settleTable surfaces split_not_fully_paid verbatim', () async {
    final api = _FakeApiService()
      ..settleError = const ApiException('split_not_fully_paid', code: 422);
    final provider = TableProvider(api: api);

    expect(
      await provider.settleTable(cartId: 'cart-1', paymentType: 'CASH'),
      isFalse,
    );
    expect(provider.errorMessage, 'split_not_fully_paid');
  });

  test('BillBuilder splits 21.90 equally across SGST and CGST', () {
    final split = BillBuilder.splitTax(21.9, [
      {'name': 'SGST', 'value_amount': '2.5'},
      {'name': 'CGST', 'value_amount': '2.5'},
    ]);

    expect(split.map((e) => e.value), [10.95, 10.95]);
  });
}

class _FakeApiService extends ApiService {
  List<TableArea> areasResult = [];
  List<DineInTable> tablesResult = [];
  ApiException? floorError;
  ApiException? settleError;

  @override
  Future<List<Map<String, dynamic>>> getAreaMaps() async {
    if (floorError != null) throw floorError!;
    return [
      for (final a in areasResult) {'_id': a.id, 'name': a.name},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getTableMaps() async {
    if (floorError != null) throw floorError!;
    return [
      for (final t in tablesResult)
        {'_id': t.id, 'table_number': t.tableNumber, 'area_id': t.areaId},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getReservations({
    String acceptedStatus = '1',
  }) async => [];

  @override
  Future<List<Map<String, dynamic>>> getLiveOrders() async => [];

  @override
  Future<ApiEnvelope> settleBill({
    required String cartId,
    required String paymentType,
  }) async {
    if (settleError != null) throw settleError!;
    return const ApiEnvelope(code: 200, message: 'ok', data: null, raw: {});
  }
}

DineInTable _table(String id) {
  return DineInTable(
    id: id,
    tableNumber: '1',
    areaId: 'area-1',
    noOfPeople: 4,
    tableStatus: 'BLANK',
    status: 'available',
    totalPrice: 0,
    itemCount: 0,
  );
}
