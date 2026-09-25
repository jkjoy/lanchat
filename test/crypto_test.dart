import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/pair_crypto.dart';

void main() {
  test('配对加密:同一口令可加解密往返', () async {
    final a = await PairCrypto.fromPassphrase('123456');
    final cipher = await a.encrypt('你好,局域网!');
    // 密文应为 base64,且不含明文。
    expect(cipher, isNot(contains('你好')));
    final clear = await a.decrypt(cipher);
    expect(clear, '你好,局域网!');
  });

  test('配对加密:不同口令无法解密(密钥不同)', () async {
    final a = await PairCrypto.fromPassphrase('123456');
    final b = await PairCrypto.fromPassphrase('654321');
    final cipher = await a.encrypt('秘密消息');
    // b 与 a 密钥不同,解密必然失败。
    await expectLater(
      () => b.decrypt(cipher),
      throwsA(isA<Object>()),
    );
  });

  test('SessionCrypto:未启用直通,启用后加密封装', () async {
    final s = SessionCrypto();
    expect(s.enabled, isFalse);
    final direct = await s.seal('明文');
    expect(direct, '明文');
    final opened = await s.open('明文');
    expect(opened, '明文');

    await s.enable('abcdef');
    expect(s.enabled, isTrue);
    final sealed = await s.seal('机密');
    expect(sealed, isNot('机密'));
    expect(await s.open(sealed), '机密');

    s.disable();
    expect(s.enabled, isFalse);
  });
}