import 'package:flutter_test/flutter_test.dart';

import 'package:lanchat/core/group.dart';

void main() {
  test('Group JSON 序列化往返一致', () {
    final g = Group(
      id: 'group-abc123',
      name: 'Family',
      ownerId: 'dev-a',
      memberIds: ['dev-a', 'dev-b', 'dev-c'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(1720000000000),
      joined: true,
    );
    final json = g.toJson();
    final restored = Group.fromJson(json);
    expect(restored.id, g.id);
    expect(restored.name, g.name);
    expect(restored.ownerId, g.ownerId);
    expect(restored.memberIds, g.memberIds);
    expect(restored.joined, isTrue);
  });

  test('Group.copyWith 成员变更', () {
    final g = Group(
      id: 'group-xyz',
      name: 'Dev',
      ownerId: 'a',
      memberIds: ['a', 'b'],
      createdAt: DateTime.now(),
      joined: true,
    );
    final updated = g.copyWith(memberIds: ['a', 'b', 'c']);
    expect(updated.memberIds.length, 3);
    expect(updated.name, 'Dev');
  });

  test('Group.contains', () {
    final g = Group(
      id: 'group-x',
      name: 'X',
      ownerId: 'o',
      memberIds: ['o', 'u1', 'u2'],
      createdAt: DateTime.now(),
    );
    expect(g.contains('u1'), isTrue);
    expect(g.contains('unknown'), isFalse);
  });

  test('GroupMessage 构造', () {
    final m = GroupMessage(
      id: 'msg-1',
      groupId: 'group-x',
      senderId: 'dev-a',
      senderName: 'Alice',
      text: 'hi',
      ts: 1720000000000,
      outbound: false,
    );
    expect(m.groupId, 'group-x');
    expect(m.senderName, 'Alice');
    expect(m.outbound, isFalse);
    expect(m.deliveredCount, 0);
    expect(m.totalCount, 0);
    expect(m.statusLabel, isEmpty);
  });

  test('GroupMessage copyWith 更新送达状态', () {
    final m = GroupMessage(
      id: 'msg-2',
      groupId: 'group-x',
      senderId: 'dev-a',
      senderName: 'Alice',
      text: 'hi all',
      ts: 1720000000001,
      outbound: true,
      totalCount: 3,
    );
    expect(m.statusLabel, '0/3 已送达');
    final upd = m.copyWith(deliveredCount: 2);
    expect(upd.deliveredCount, 2);
    expect(upd.statusLabel, '2/3 已送达');
  });
}