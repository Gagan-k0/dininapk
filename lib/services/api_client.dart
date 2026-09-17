import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' show DateFormat;

import '../config/api_config.dart';
import 'auth_service.dart';
import 'connectivity_service.dart';
import 'device_id_service.dart';
import 'subscription_rules.dart';
import 'subscription_service.dart';

/// A refusal or transport failure from the FatFox API.
///
/// The API almost always answers HTTP 200 and puts the real outcome in
/// `status.code` (200 = ok, 4xx/5xx = refused). Only JWT/tenant failures use a
/// real HTTP 401. Callers must therefore branch on [code], never on HTTP status.
class ApiException implements Exception {
  final int code;
  final String message;
  final int? httpStatus;

  /// Session is invalid/expired (HTTP 401, or envelope code 401 / 2024).
  final bool isAuth;

  /// Transport-level failure (DNS, socket, timeout) — the request never got a
  /// verdict from the server.
  final bool isNetwork;

  /// Machine-readable detail some endpoints attach (`data.reason`, `data.code`).
  final dynamic data;

  /// Non-numeric `status.code` (e.g. `table_claimed_by_another_device`), which
  /// some endpoints send instead of a number — [code] cannot carry it.
  final String reason;

  const ApiException(
    this.message, {
    this.code = 500,
    this.httpStatus,
    this.isAuth = false,
    this.isNetwork = false,
    this.data,
    this.reason = '',
  });

  /// Another tablet holds this table's claim (`helpers/tableClaim.js`).
  bool get isTableClaimed => reason == 'table_claimed_by_another_device';

  /// The restaurant's subscription is locked or the restaurant is blocked
  /// (HTTP 403). Not a session expiry: keep the session and any queued sends.
  bool get isSubscriptionLocked =>
      reason == subscriptionLockedCode || reason == restaurantBlockedCode;

  /// Device id holding the claim, when the server named it.
  String? get claimHeldBy =>
      data is Map ? (data as Map)['held_by']?.toString() : null;

  /// Who holds the claim and why, for the waiter. `held_by_kind` and
  /// `expires_at` are newer server fields; older servers send neither.
  String get claimMessage {
    final m = data is Map ? data as Map : const {};
    final at = DateTime.tryParse(m['expires_at']?.toString() ?? '');
    final until = at == null || at.isBefore(DateTime.now())
        ? ''
        : ' until ${DateFormat('h:mm a').format(at.toLocal())}';
    return switch (m['held_by_kind']?.toString()) {
      'admin_panel' => 'Held by the admin panel$until.',
      'tablet' => 'Held by another tablet$until.',
      'guest' => 'A guest is ordering by QR on this table.',
      _ => 'Another tablet is serving this table.',
    };
  }

  @override
  String toString() => message;
}

/// Decoded FatFox envelope: `{ status: { code, message }, data }`.
class ApiEnvelope {
  final int code;
  final String message;
  final dynamic data;
  final Map<String, dynamic> raw;

  /// `status.code` when it is a word, not a number (the offline/claim endpoints
  /// answer e.g. `table_claimed_by_another_device`); '' otherwise.
  final String reason;

  const ApiEnvelope({
    required this.code,
    required this.message,
    required this.data,
    required this.raw,
    this.reason = '',
  });

  bool get ok => code == 200 || code == 0;

  /// `data` as a list; tolerates `data.docs` (paginated) and a missing key.
  List<dynamic> get list {
    if (data is List) return data as List;
    if (data is Map && (data as Map)['docs'] is List) {
      return (data as Map)['docs'] as List;
    }
    return const [];
  }

  List<Map<String, dynamic>> get mapList => list
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);

  Map<String, dynamic>? get map =>
      data is Map ? Map<String, dynamic>.from(data as Map) : null;

  static ApiEnvelope parse(Map<String, dynamic> raw) {
    final status = raw['status'];
    int code = -1;
    String message = '';
    String reason = '';
    if (status is Map) {
      final c = status['code'];
      code = c is int ? c : int.tryParse(c?.toString() ?? '') ?? -1;
      if (code == -1 && c != null && c.toString().trim().isNotEmpty) {
        reason = c.toString().trim();
      }
      message = status['message']?.toString() ?? '';
    } else if (status is String) {
      message = status;
    }
    if (message.isEmpty && raw['message'] != null) {
      message = raw['message'].toString();
    }
    if (code == -1 && message.isEmpty) {
      message = 'Malformed response from server';
    }
    return ApiEnvelope(
      code: code,
      message: message,
      data: raw['data'],
      raw: raw,
      reason: reason,
    );
  }
}

/// Thin HTTP layer shared by every service: builds the URL, attaches the JWT,
/// applies a timeout, decodes the envelope and turns refusals into
/// [ApiException]. A 401 fires [onSessionExpired] once so the app can return to
/// login — except for `background` calls (offline sync) which must never log the
/// cashier out mid-shift.
class ApiClient {
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Invoked (at most once per expiry) when the server rejects the session.
  static void Function(String reason)? onSessionExpired;
  static bool _expiryNotified = false;

  /// Reset after a fresh login so the next expiry notifies again.
  static void sessionRefreshed() => _expiryNotified = false;

  final AuthService _auth;
  final http.Client _http;
  final DeviceIdService _deviceId = DeviceIdService();

  ApiClient({AuthService? auth, http.Client? httpClient})
    : _auth = auth ?? AuthService(),
      _http = httpClient ?? http.Client();

  Uri uri(String path, [Map<String, String?>? query]) {
    final base = Uri.parse('${ApiConfig.cleanBaseUrl}$path');
    if (query == null || query.isEmpty) return base;
    final q = <String, String>{...base.queryParameters};
    query.forEach((k, v) => q[k] = v ?? '');
    return base.replace(queryParameters: q);
  }

  Future<ApiEnvelope> get(
    String path, {
    Map<String, String?>? query,
    bool background = false,
    Duration? timeout,
  }) => request(
    'GET',
    path,
    query: query,
    background: background,
    timeout: timeout,
  );

  Future<ApiEnvelope> post(
    String path, {
    Object? body,
    Map<String, String?>? query,
    Map<String, String>? extraHeaders,
    bool background = false,
    Duration? timeout,
  }) => request(
    'POST',
    path,
    body: body,
    query: query,
    extraHeaders: extraHeaders,
    background: background,
    timeout: timeout,
  );

  Future<ApiEnvelope> put(
    String path, {
    Object? body,
    bool background = false,
  }) => request('PUT', path, body: body, background: background);

  Future<ApiEnvelope> patch(String path, {Object? body}) =>
      request('PATCH', path, body: body);

  Future<ApiEnvelope> delete(String path, {Map<String, String?>? query}) =>
      request('DELETE', path, query: query);

  /// Performs the call and returns the envelope **only when it is a success**.
  /// Any refusal (HTTP ≥ 400, or envelope code ≠ 200/0) throws [ApiException].
  Future<ApiEnvelope> request(
    String method,
    String path, {
    Object? body,
    Map<String, String?>? query,
    Map<String, String>? extraHeaders,
    bool background = false,
    Duration? timeout,
  }) async {
    if (await _auth.isDemoMode()) {
      throw const ApiException(
        'Demo mode — no live data. Log in with restaurant credentials.',
        code: 0,
      );
    }
    final token = await _auth.getToken();
    final net = ConnectivityService.instance;
    // Sync off means nothing leaves the tablet. Login (no token yet) is exempt,
    // or a waiter who switched Sync off could never sign back in.
    if (net.syncOff && token != null && token.isNotEmpty) {
      throw const ApiException(
        'Sync is off. Turn Sync on to reach the server.',
        code: 0,
        isNetwork: true,
      );
    }
    final restId = await _auth.getRestaurantId();
    final deviceId = await _deviceId.get();
    final url = uri(path, query);
    final headers = {
      ...ApiConfig.headers(token, restId, deviceId: deviceId),
      if (extraHeaders != null) ...extraHeaders,
    };
    final encoded = body == null
        ? null
        : (body is String ? body : jsonEncode(body));

    http.Response response;
    try {
      final req = http.Request(method, url)..headers.addAll(headers);
      if (encoded != null) req.body = encoded;
      final streamed = await _http.send(req).timeout(timeout ?? defaultTimeout);
      response = await http.Response.fromStream(streamed);
      net.reportReachable();
    } on TimeoutException {
      net.reportNetworkFailure();
      throw ApiException(
        'Server did not respond in time. Check Wi-Fi and try again.',
        code: 0,
        isNetwork: true,
      );
    } on SocketException catch (e) {
      net.reportNetworkFailure();
      throw ApiException(_networkMessage(e), code: 0, isNetwork: true);
    } on http.ClientException catch (e) {
      net.reportNetworkFailure();
      throw ApiException(_networkMessage(e), code: 0, isNetwork: true);
    }

    debugPrint(
      '[Fatfox API] $method ${url.path} → HTTP ${response.statusCode}',
    );

    Map<String, dynamic> raw;
    try {
      final decoded = response.body.isEmpty ? {} : jsonDecode(response.body);
      raw = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : {'data': decoded};
    } catch (_) {
      raw = {};
    }
    final env = ApiEnvelope.parse(raw);

    final authFailed =
        response.statusCode == 401 || env.code == 401 || env.code == 2024;
    if (authFailed) {
      final msg = env.message.isNotEmpty
          ? env.message
          : 'Session expired. Please log in again.';
      if (!background) _notifyExpired(msg);
      throw ApiException(
        msg,
        code: 401,
        httpStatus: response.statusCode,
        isAuth: true,
      );
    }

    if (response.statusCode == 429) {
      throw ApiException(
        env.message.isNotEmpty
            ? env.message
            : 'Too many attempts. Try again shortly.',
        code: 429,
        httpStatus: 429,
      );
    }

    if (env.reason == subscriptionLockedCode ||
        env.reason == restaurantBlockedCode) {
      // The lock screen follows from the new state; never onSessionExpired.
      final data = env.map;
      if (data != null) unawaited(SubscriptionService.instance.apply(data));
    }

    if (response.statusCode >= 400 || !env.ok) {
      final fallback = response.statusCode >= 400
          ? 'Request failed (HTTP ${response.statusCode})'
          : 'Request refused';
      throw ApiException(
        env.message.isNotEmpty ? env.message : fallback,
        code: env.code == 200 || env.code == 0 ? response.statusCode : env.code,
        httpStatus: response.statusCode,
        data: env.data,
        reason: env.reason,
      );
    }
    return env;
  }

  void _notifyExpired(String reason) {
    if (_expiryNotified) return;
    _expiryNotified = true;
    final cb = onSessionExpired;
    if (cb != null) cb(reason);
  }

  static String _networkMessage(Object e) {
    final s = e.toString();
    if (s.contains('Failed host lookup') ||
        s.contains('Network is unreachable')) {
      return 'No internet / DNS on this device. Cannot reach ${ApiConfig.cleanBaseUrl}.';
    }
    return 'Cannot reach the server. Check Wi-Fi and try again.';
  }
}

/// Human-readable text for any error a provider caught.
String friendlyError(
  Object e, [
  String fallback = 'Something went wrong. Please try again.',
]) {
  if (e is ApiException) return e.message.isNotEmpty ? e.message : fallback;
  final s = e.toString().replaceAll('Exception: ', '').trim();
  return s.isEmpty ? fallback : s;
}
