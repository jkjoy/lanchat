import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/database.dart';

void main() {
  test('searchMessages:LIKE 跨会话检索并按时间倒序', () async {
    final db = LocalDatabase.instance;

    // 使用独立数据库路径,避免影响真实数据;通过 open 注入? 没有注入点,
    // 直接用临时数据库工厂打开(桌面 FFI 已在 open 中初始化)。
    final dir = Directory.systemTemp.createTempSync('lanchat_db_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    // 覆写数据库路径不可行(singleton),这里退而调用 open 后用真实库,
    // 但会污染测试用 DB;故此处直接操作单例,用例结束后清空相关 peer 数据。
    await db.open();

    final ts = DateTime.now().millisecondsSinceEpoch;
    // 插入几条不同的消息。
    await db.insertMessage(MessageRow(
      id: 's1',
      peerId: 'peer-a',
      direction: 0,
      type: 'chat',
      ts: ts - 3000,
      status: 'sent',
      payload: '你好,今晚吃饭吗',
    ));
    await db.insertMessage(MessageRow(
      id: 's2',
      peerId: 'group-g1',
      direction: 1,
      type: 'group_chat',
      ts: ts - 2000,
      status: 'delivered',
      payload: '(Bob) 一起开会',
    ));
    await db.insertMessage(MessageRow(
      id: 's3',
      peerId: 'peer-b',
      direction: 1,
      type: 'chat',
      ts: ts - 1000,
      status: 'delivered',
      payload: '好的,开完会说',
    ));

    // 搜索"开会"应命中 s2(仅 s2 含连续"开会")。
    final results = await db.searchMessages('开会');
    expect(results.length, 1);
    expect(results.first.id, 's2');

    // 搜索"开"应命中 s3 与 s2,倒序 s3 在前。
    final kai = await db.searchMessages('开');
    expect(kai.length, 2);
    expect(kai.first.id, 's3');
    expect(kai.last.id, 's2');

    // 搜索"吃饭"应命中 s1。
    final eat = await db.searchMessages('吃饭');
    expect(eat.length, 1);
    expect(eat.first.peerId, 'peer-a');

    // 搜索不存在返回空。
    final none = await db.searchMessages('不存在词xyz');
    expect(none, isEmpty);

    // 清理。
    await db.clearMessages('peer-a');
    await db.clearMessages('peer-b');
    await db.clearMessages('group-g1');
  });
}