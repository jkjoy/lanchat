import 'package:flutter/foundation.dart';

/// 一个局域网群组：由一位创建者发起，邀请若干在线设备加入。
@immutable
class Group {
  final String id;
  final String name;
  final String ownerId; // 创建者设备 ID
  final List<String> memberIds;
  final DateTime createdAt;
  final bool joined; // 本机是否已加入（收到邀请后为 true）

  const Group({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.memberIds,
    required this.createdAt,
    this.joined = true,
  });

  bool get isOwner => false; // ownerId 与本机对比在服务层完成
  bool contains(String deviceId) => memberIds.contains(deviceId);

  Group copyWith({
    String? name,
    List<String>? memberIds,
    bool? joined,
  }) =>
      Group(
        id: id,
        name: name ?? this.name,
        ownerId: ownerId,
        memberIds: memberIds ?? this.memberIds,
        createdAt: createdAt,
        joined: joined ?? this.joined,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'owner': ownerId,
        'members': memberIds,
        'created': createdAt.millisecondsSinceEpoch,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '群聊',
        ownerId: (j['owner'] as String?) ?? '',
        memberIds:
            ((j['members'] as List?) ?? const []).cast<String>(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['created'] as int?) ?? 0),
      );
}

/// 群消息（与私聊消息同构，多一个 senderName 用于展示）。
@immutable
class GroupMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String senderName;
  final String text;
  final int ts;
  final bool outbound;
  final int deliveredCount;
  final int totalCount;

  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.ts,
    required this.outbound,
    this.deliveredCount = 0,
    this.totalCount = 0,
  });

  GroupMessage copyWith({int? deliveredCount, int? totalCount}) =>
      GroupMessage(
        id: id,
        groupId: groupId,
        senderId: senderId,
        senderName: senderName,
        text: text,
        ts: ts,
        outbound: outbound,
        deliveredCount: deliveredCount ?? this.deliveredCount,
        totalCount: totalCount ?? this.totalCount,
      );

  String get statusLabel {
    if (totalCount <= 0) return '';
    return '$deliveredCount/$totalCount 已送达';
  }
}