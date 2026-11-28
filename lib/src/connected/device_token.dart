import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the phone keeps its server token.
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// The iOS Keychain / Android Keystore: not in the app's files, so not in
/// a backup or a copied database. On iOS it stays on this device only.
class SecureTokenStore implements TokenStore {
  static const _key = 'trustpunch.serverToken';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// For tests.
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.token]);

  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async => token = value;

  @override
  Future<void> delete() async => token = null;
}
