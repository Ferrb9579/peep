import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small keystore-backed record store for private on-device data.
///
/// Android encrypts values with a key held by the Android keystore. The same
/// API uses the browser's protected storage implementation on web builds.
class EncryptedStore {
  EncryptedStore._();

  static final instance = EncryptedStore._();

  static const _storage = FlutterSecureStorage();

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> delete(String key) => _storage.delete(key: key);

  Future<Map<String, String>> readAll() => _storage.readAll();
}
