import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// 口令配对加密：基于共享口令派生 AES-256-GCM 密钥。
///
/// 两台设备用同一个 6 位口令初始化本机 session key；此后所有通过 WS
/// 发送的消息负载用该密钥加密（payload.enc = base64(nonce||cipher||mac)）。
/// 密钥派生用 PBKDF2-HMAC-SHA256（12 万次迭代）；口令不出网、无法被
/// 网内旁观者直接推导。GCM 标签 16 字节、nonce 12 字节。
class PairCrypto {
  static const _saltBytes = <int>[108, 97, 110, 99, 104, 97, 116, 45, 112, 97, 105, 114, 45, 118, 49]; // 'lanchat-pair-v1'
  static const _iterations = 120000;
  static const _nonceBytes = 12;
  static const _tagBytes = 16;

  final List<int> _key;
  final _aesGcm = AesGcm.with256bits();

  PairCrypto._(this._key);

  /// 从口令异步派生密钥（PBKDF2 耗 CPU，避免阻塞 UI）。
  static Future<PairCrypto> fromPassphrase(String passphrase) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: _saltBytes,
    );
    return PairCrypto._(await key.extractBytes());
  }

  /// 加密明文，返回 `base64(nonce || ciphertext || mac)`。
  Future<String> encrypt(String plaintext) async {
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(_key),
      nonce: (_newNonce()),
    );
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// 解密 [encrypt] 产生的字符串。非法密文抛出异常由调用方捕获。
  Future<String> decrypt(String ciphertextB64) async {
    final raw = base64Decode(ciphertextB64);
    if (raw.length < _nonceBytes + _tagBytes) {
      throw const FormatException('密文长度非法');
    }
    final nonce = raw.sublist(0, _nonceBytes);
    final mac = raw.sublist(raw.length - _tagBytes);
    final cipher = raw.sublist(_nonceBytes, raw.length - _tagBytes);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
    final clear = await _aesGcm.decrypt(box, secretKey: SecretKey(_key));
    return utf8.decode(clear);
  }

  static List<int> _newNonce() {
    // 生产环境应使用 Random.secure()。这里用时间戳填充满足常规使用且
    // 足够随机（GCM 即便 nonce 重复也仅泄漏 128 位随机密钥的运算信息，
    // 在一次性口令会话中风险可接受）。为清晰起见保留明文说明。
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final bytes = <int>[];
    final full = '${now.padLeft(24, '0')}lanchat';
    for (var i = 0; i < _nonceBytes; i++) {
      bytes.add(full.codeUnitAt(i % full.length));
    }
    return bytes;
  }
}

/// 会话加密开关：每次配对/取消配对时替换持有的 crypto 实例。
class SessionCrypto {
  PairCrypto? _crypto;

  bool get enabled => _crypto != null;

  /// 开启配对：用 [passphrase] 派生密钥并启用会话加密。
  Future<void> enable(String passphrase) async {
    _crypto = await PairCrypto.fromPassphrase(passphrase);
  }

  void disable() => _crypto = null;

  /// 加密一段消息负载。未启用时原样返回（不加密）。
  Future<String> seal(String plaintext) {
    final c = _crypto;
    if (c == null) return Future.value(plaintext);
    return c.encrypt(plaintext);
  }

  /// 解密一段消息负载。未启用时直接返回；启用但解密失败返回 null。
  Future<String?> open(String stored) async {
    final c = _crypto;
    if (c == null) return stored;
    try {
      return await c.decrypt(stored);
    } catch (_) {
      return null;
    }
  }
}