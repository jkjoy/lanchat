import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/file_transfer.dart';
import 'package:lanchat/core/models.dart';

void main() {
  test('文件传输:发送方 offer → 接收方 accept → 字节一致', () async {
    final tmp = Directory.systemTemp.createTempSync('lanchat_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // 发送方文件。
    final src = File('${tmp.path}/hello.txt');
    final content = List<int>.generate(300000, (i) => i % 251);
    await src.writeAsBytes(content);

    final alice = DeviceInfo(id: 'alice', name: 'Alice', platform: 'macos');
    final bob = DeviceInfo(id: 'bob', name: 'Bob', platform: 'windows');

    // 内存信令路由器:把一方的信封转发给另一方 handleEnvelope。
    final router = _PairSignaler();

    final outbound = FileTransferService(self: alice, conn: router);
    await outbound.start(port: 54201, saveRoot: Directory('${tmp.path}/save_a'));
    final inbound = FileTransferService(self: bob, conn: router);
    await inbound.start(port: 54202, saveRoot: Directory('${tmp.path}/save_b'));
    router.register(alice.id, outbound);
    router.register(bob.id, inbound);

    final peerBob = Peer(
      id: 'bob',
      name: 'Bob',
      platform: 'windows',
      host: '127.0.0.1',
      port: 54202,
      lastSeen: DateTime.now(),
      online: true,
    );
    final peerAlice = Peer(
      id: 'alice',
      name: 'Alice',
      platform: 'macos',
      host: '127.0.0.1',
      port: 54201,
      lastSeen: DateTime.now(),
      online: true,
    );

    // 发送方发起 offer。
    final transferId = await outbound.offerFile(peerBob, src.path);
    expect(outbound.transfersNotifier.value.length, 1);

    // 等接收方通过信令路由收到 offer。
    await _waitFor(
        () => inbound.transfersNotifier.value.any((v) => v.id == transferId));
    final accId = inbound.transfersNotifier.value
        .firstWhere((v) => v.id == transferId)
        .id;

    // 接收方 accept → 下载(信令回传使发送方允许 HTTP 拉取)。
    await inbound.acceptTransfer(accId, peerAlice);

    // 等待接收方完成。
    await _waitFor(() {
      final v = inbound.transfersNotifier.value
          .firstWhere((t) => t.id == transferId);
      return v.status == TransferStatus.done;
    }, timeout: const Duration(seconds: 10));

    // 校验文件内容一致。
    final saved = File('${tmp.path}/save_b/hello.txt');
    expect(await saved.exists(), isTrue);
    final bytes = await saved.readAsBytes();
    expect(bytes.length, content.length);
    expect(bytes, content);

    await outbound.close();
    await inbound.close();
  });
}

/// 测试用内存信令路由器:把信封按 to 转发给注册的另一台传输服务。
class _PairSignaler implements TransferSignaler {
  final Map<String, FileTransferService> _peers = {};

  void register(String id, FileTransferService svc) => _peers[id] = svc;

  @override
  bool send(String peerId, Envelope envelope) {
    final target = _peers[peerId];
    final sender = _peers[envelope.from];
    if (target == null || sender == null) return false;
    // 用发送方传输服务的 self 构造对端 Peer(仅 host/port 无实际意义,
    // handleEnvelope 用到的传输参数都来自信封本身)。
    final fromSelf = sender.self;
    final peer = Peer(
      id: fromSelf.id,
      name: fromSelf.name,
      platform: fromSelf.platform,
      host: '127.0.0.1',
      port: sender.serverPort,
      lastSeen: DateTime.now(),
      online: true,
    );
    target.handleEnvelope(envelope, peer);
    return true;
  }
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