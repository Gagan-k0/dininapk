import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/providers/auth_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('AuthProvider restores session when token and restaurant_id exist in SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'test-jwt-token-123',
      'restaurant_id': 'rest-id-456',
      'restaurant_name': 'My Resto',
    });

    final auth = AuthProvider();
    await auth.checkSession();

    expect(auth.isLoggedIn, isTrue);
    expect(auth.token, 'test-jwt-token-123');
    expect(auth.restaurantId, 'rest-id-456');
    expect(auth.restaurantName, 'My Resto');
  });

  test('AuthProvider is NOT logged in when SharedPreferences has no token', () async {
    SharedPreferences.setMockInitialValues({});

    final auth = AuthProvider();
    await auth.checkSession();

    expect(auth.isLoggedIn, isFalse);
    expect(auth.token, isNull);
    expect(auth.restaurantId, isNull);
  });

  test('logout removes token and clears session state', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'valid-token',
      'restaurant_id': 'rest-123',
    });

    final auth = AuthProvider();
    await auth.checkSession();
    expect(auth.isLoggedIn, isTrue);

    await auth.logout();

    expect(auth.isLoggedIn, isFalse);
    expect(auth.token, isNull);
    expect(auth.restaurantId, isNull);

    final newAuth = AuthProvider();
    await newAuth.checkSession();
    expect(newAuth.isLoggedIn, isFalse);
  });
}
