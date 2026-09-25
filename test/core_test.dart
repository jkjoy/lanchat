import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/discovery.dart';
import 'package:lanchat/core/models.dart';

void main() {
  test('Envelope 编解码往返一致', () {
    final env = Envelope.chat(from: 'a', to: 'b', text: '你好');
    final decoded = Envelope.fromJson(
      Map<String, dynamic>.from(env.toJson()),
    );
    expect(decoded.type, Envelope.typeChat);
    expect(decoded.from, 'a');
    expect(decoded.to, 'b');
    expect(decoded.payload['text'], '你好');
    expect(decoded.id, env.id);
    expect(decoded.ts, env.ts);
  });

  test('Peer DB 序列化往返一致', () {
    final peer = Peer(
      id: 'dev-1',
      name: 'Xray',
      platform: 'windows',
      host: '192.168.1.5',
      port: 53921,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      online: true,
    );
    final restored = Peer.fromDb(peer.toDb());
    expect(restored.id, peer.id);
    expect(restored.name, peer.name);
    expect(restored.platform, peer.platform);
    expect(restored.host, peer.host);
    expect(restored.port, peer.port);
    expect(restored.online, peer.online);
  });

  test('发现协议:收到合法广播报文后产生 Peer 事件', () async {
    final self = DeviceInfo(id: 'me', name: 'Me', platform: 'macos');
    final d = DeviceDiscovery.withPort(
      self,
      serverPort: 54000,
      advertisePort: 53925,
    );
    await d.start();

    final foundCv = StreamController<Peer>();
    d.found.listen(foundCv.add);

    final sender =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final bytes =
        '{"t":"lanchat:announce","id":"dev-x","name":"Xray","platform":"windows","port":53921}';
    sender.send(bytes.codeUnits, InternetAddress.loopbackIPv4, 53925);

    // 等待 2 秒内收到 Xray。
    final peer = await foundCv.stream
        .timeout(const Duration(seconds: 2))
        .firstWhere((p) => p.id == 'dev-x');

    expect(peer.host, isNotEmpty);
    expect(peer.name, 'Xray');
    expect(peer.port, 53921);

    sender.close();
    await d.stop();
    await foundCv.close();
  });

  test('离线判定:超过阈值未广播的设备进入 gone', () async {
    final self = DeviceInfo(id: 'me', name: 'Me', platform: 'macos');
    final d = DeviceDiscovery.withPort(
      self,
      serverPort: 54001,
      advertisePort: 53926,
    );
    await d.start();

    final goneCv = StreamController<String>();
    d.gone.listen(goneCv.add);

    final sender =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    sender.send(
      '{"t":"lanchat:announce","id":"dev-y","name":"Yankee","platform":"android","port":53921}'
          .codeUnits,
      InternetAddress.loopbackIPv4,
      53926,
    );

    // 等收到发现。
    await d.found
        .timeout(const Duration(seconds: 2))
        .firstWhere((p) => p.id == 'dev-y');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    d.checkGone(timeout: const Duration(milliseconds: 100));

    final gone = await goneCv.stream
        .timeout(const Duration(seconds: 2))
        .firstWhere((id) => id == 'dev-y');
    expect(gone, 'dev-y');

    sender.close();
    await d.stop();
    await goneCv.close();
  });
}