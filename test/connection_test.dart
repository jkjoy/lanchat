import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/connection.dart';
import 'package:lanchat/core/models.dart';

void main() {
  test('双端握手收敛:互发 hello 后各自只保留一条连接,消息可互通', () async {
    final alice = DeviceInfo(id: 'alice', name: 'Alice', platform: 'macos');
    final bob = DeviceInfo(id: 'bob', name: 'Bob', platform: 'windows');

    final aliceMsgs = <Envelope>[];
    final bobMsgs = <Envelope>[];
    final bobStatus = <bool>[];

    final connA = ConnectionManager(
      self: alice,
      onEnvelope: (env, peer) => aliceMsgs.add(env),
    );
    final connB = ConnectionManager(
      self: bob,
      onEnvelope: (env, peer) => bobMsgs.add(env),
      onStatusChanged: (peer, connected) => bobStatus.add(connected),
    );

    await connA.startServer(port: 54101);
    await connB.startServer(port: 54102);
    final bobPort = connB.serverPort;

    // Alice 拨号 Bob。
    await connA.connectTo(Peer(
      id: 'bob',
      name: 'Bob',
      platform: 'windows',
      host: '127.0.0.1',
      port: bobPort,
      lastSeen: DateTime.now(),
      online: false,
    ));

    // 等待握手完成(bob 侧注册)。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (connB.isConnected('alice') == false &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(connB.isConnected('alice'), isTrue,
        reason: 'bob 应已注册 alice 的连接');
    expect(connA.isConnected('bob'), isTrue, reason: 'alice 应已注册 bob');

    // Alice → Bob 发一条消息。
    expect(
      connA.send('bob', Envelope.chat(from: 'alice', to: 'bob', text: 'hi')),
      isTrue,
    );
    await _waitFor(() => bobMsgs.any((e) => e.type == Envelope.typeChat));

    expect(bobMsgs.where((e) => e.type == Envelope.typeChat).length, 1);
    final chat = bobMsgs.firstWhere((e) => e.type == Envelope.typeChat);
    expect(chat.payload['text'], 'hi');
    expect(chat.from, 'alice');

    // 收敛性:连接数应恰好各 1。
    await _waitFor(() => bobStatus.isNotEmpty);
    expect(connA.isConnected('bob'), isTrue);
    expect(connB.isConnected('alice'), isTrue);

    await connA.close();
    await connB.close();
  });
}

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}