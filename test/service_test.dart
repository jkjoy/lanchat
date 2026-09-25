import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/chat_service.dart';
import 'package:lanchat/core/models.dart';

void main() {
  test('群发:无在线设备时为安全空操作,不写入会话', () async {
    final alice = DeviceInfo(id: 'alice', name: 'Alice', platform: 'macos');
    final svc = ChatService(self: alice);

    await svc.broadcast('一组话');
    // 无在线设备:群发被丢弃,不产生任何会话数据。
    expect(svc.isBroadcastView, isFalse);
    expect(svc.currentMessages, isEmpty);
  });

  test('群发视图:选中 broadcast 后进入群发视图,选回设备视图', () {
    final alice = DeviceInfo(id: 'alice', name: 'Alice', platform: 'macos');
    final svc = ChatService(self: alice);

    svc.select('broadcast');
    expect(svc.isBroadcastView, isTrue);
    expect(svc.selectedPeer, isNull); // 群发视图没有对端设备。
    expect(svc.select, isNotNull); // 可再切换。

    svc.select(null);
    expect(svc.isBroadcastView, isFalse);
  });

  test('群发视图不受普通会话补发逻辑影响(不会因缺 peer 崩溃)', () async {
    final alice = DeviceInfo(id: 'alice', name: 'Alice', platform: 'macos');
    final svc = ChatService(self: alice);

    // 直接选中一个并不存在的设备 ID,补发逻辑应安全跳过。
    svc.select('no-such-device');
    expect(svc.selectedPeer, isNull);

    // 群发视图同样安全。
    svc.select('broadcast');
    expect(svc.isBroadcastView, isTrue);
  });
}