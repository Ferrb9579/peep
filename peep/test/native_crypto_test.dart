import 'package:flutter_test/flutter_test.dart';
import 'package:peep/webrtc_peer_native.dart';

void main() {
  test('native encryption primitives round-trip', () async {
    await runNativeCryptoSelfTest();
  });
}
