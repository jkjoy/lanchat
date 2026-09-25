import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/chat_service.dart';
import 'package:lanchat/core/connection.dart';
import 'package:lanchat/core/database.dart';
import 'package:lanchat/core/models.dart';

void main() {
  test('历史恢复:loadHistory 从 DB 恢复私聊/群发/群聊会话', () async {
    final db = LocalDatabase.instance;
    await db.open();

    final ts = DateTime.now().millisecondsSinceEpoch;
    // 三个会话的历史:私聊、群发、群聊。
    await db.insertMessage(MessageRow(
      id: 'h1',
      peerId: 'peer-x',
      direction: 1,
      type: 'chat',
      ts: ts - 3000,
      status: 'delivered',
      payload: '私聊消息',
    ));
    await db.insertMessage(MessageRow(
      id: 'h2',
      peerId: 'broadcast',
      direction: 1,
      type: 'chat',
      ts: ts - 2000,
      status: 'delivered',
      payload: '(Bob) 群发消息',
    ));
    await db.insertMessage(MessageRow(
      id: 'h3',
      peerId: 'group-test1',
      direction: 1,
      type: 'group_chat',
      ts: ts - 1000,
      status: 'delivered',
      payload: '(Bob) 群聊消息',
    ));

    final self = DeviceInfo(id: 'self-dev', name: 'Self', platform: 'macos');
    final svc = ChatService(self: self);
    await svc.loadHistory();

    // 私聊历史可见。
    svc.select('peer-x');
    expect(svc.currentMessages.length, 1);
    expect(svc.currentMessages.first.text, '私聊消息');
    expect(svc.currentMessages.first.outbound, isFalse);

    // 群发历史可见。
    svc.select('broadcast');
    expect(svc.currentMessages.length, 1);
    expect(svc.currentMessages.first.text, '(Bob) 群发消息');

    // 群聊历史可见(发送者名从 payload 前缀解析)。
    svc.select('group-test1');
    expect(svc.currentMessages.length, 1);
    expect(svc.currentMessages.first.text, contains('群聊消息'));

    // 重复调用 loadHistory 不产生重复(id 去重)。
    await svc.loadHistory();
    svc.select('peer-x');
    expect(svc.currentMessages.length, 1);

    // 清理。
    await db.clearMessages('peer-x');
    await db.clearMessages('broadcast');
    await db.clearMessages('group-test1');
  });

  test('连接收敛:同 host 的 manual-* 条目在真实设备上线后被清理', () async {
    final self = DeviceInfo(id: 'self-dev', name: 'Self', platform: 'macos');
    final svc = ChatService(self: self);
    // 先登记一个手动添加条目(不拨号,不依赖 start())。
    svc.debugAddManualPeerEntry('127.0.0.1');
    // 模拟真实设备上线回调。
    svc.debugOnStatusChanged(Peer(
      id: 'real-device-id',
      name: 'Real',
      platform: 'macos',
      host: '127.0.0.1',
      port: ConnectionManager.defaultPort,
      lastSeen: DateTime.now(),
      online: true,
    ), true);
    // 僵尸条目应已被移除(真实 ID 存在,manual- 不存在)。
    expect(svc.peer('real-device-id'), isNotNull);
    expect(svc.peer('manual-127-0-0-1'), isNull);
  });
}