import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 本机设备信息。
@immutable
class DeviceInfo {
  final String id;
  final String name;
  final String platform;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
  });

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'platform': platform};

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String? ?? 'unknown',
      );

  DeviceInfo copyWith({String? name}) {
    return DeviceInfo(id: id, name: name ?? this.name, platform: platform);
  }
}

/// 远程设备及其在线状态。
class Peer {
  final String id;
  String name;
  String platform;
  String? host;
  int? port;
  DateTime lastSeen;
  bool online;

  Peer({
    required this.id,
    required this.name,
    required this.platform,
    this.host,
    this.port,
    required this.lastSeen,
    this.online = false,
  });

  Map<String, dynamic> toDb() => {
        'id': id,
        'name': name,
        'platform': platform,
        'host': host,
        'port': port,
        'last_seen': lastSeen.millisecondsSinceEpoch,
        'online': online ? 1 : 0,
      };

  factory Peer.fromDb(Map<String, dynamic> map) => Peer(
        id: map['id'] as String,
        name: map['name'] as String,
        platform: map['platform'] as String? ?? 'unknown',
        host: map['host'] as String?,
        port: map['port'] as int?,
        lastSeen:
            DateTime.fromMillisecondsSinceEpoch((map['last_seen'] as int?) ?? 0),
        online: (map['online'] as int? ?? 0) == 1,
      );

  Peer copyWith({String? name, bool? online, DateTime? lastSeen, String? host, int? port}) {
    return Peer(
      id: id,
      name: name ?? this.name,
      platform: platform,
      host: host ?? this.host,
      port: port ?? this.port,
      lastSeen: lastSeen ?? this.lastSeen,
      online: online ?? this.online,
    );
  }
}

/// 在局域网内收发消息的应用级信封。
class Envelope {
  static const typeHello = 'hello';
  static const typePresence = 'presence';
  static const typeChat = 'chat';
  static const typeReceipt = 'receipt';
  static const typeFileOffer = 'file_offer';
  static const typeFileAccept = 'file_accept';
  static const typeFileDecline = 'file_decline';
  static const typeFileProgress = 'file_progress';
  static const typeFileDone = 'file_done';
  static const typePairEnable = 'pair_enable';
  static const typeBroadcast = 'broadcast';
  static const typeGroupCreate = 'group_create';
  static const typeGroupInvite = 'group_invite';
  static const typeGroupLeave = 'group_leave';
  static const typeGroupChat = 'group_chat';
  static const typeGroupReceipt = 'group_chat_receipt';

  final String type;
  final String from;
  final String to;
  final String id;
  final int ts;
  final Map<String, dynamic> payload;

  const Envelope({
    required this.type,
    required this.from,
    required this.to,
    required this.id,
    required this.ts,
    required this.payload,
  });

  String encode() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
        'type': type,
        'from': from,
        'to': to,
        'id': id,
        'ts': ts,
        'payload': payload,
      };

  factory Envelope.fromJson(Map<String, dynamic> json) => Envelope(
        type: json['type'] as String,
        from: json['from'] as String,
        to: json['to'] as String,
        id: json['id'] as String,
        ts: (json['ts'] as int?) ?? 0,
        payload: (json['payload'] as Map<String, dynamic>?) ?? const {},
      );

  /// 构造一个普通的聊天消息。
  factory Envelope.chat({
    required String from,
    required String to,
    required String text,
    String? id,
    String? replyTo,
  }) =>
      Envelope(
        type: typeChat,
        from: from,
        to: to,
        id: id ?? _uuid.v4(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'reply_to': ?replyTo,
          'text': text,
        },
      );

  /// 构造一个收到回执。
  factory Envelope.receipt({required String from, required String to, required String ackId}) =>
      Envelope(
        type: typeReceipt,
        from: from,
        to: to,
        id: _uuid.v4(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'ack': ackId,
        },
      );

  static const _uuid = Uuid();
}

/// 本机身份管理：设备 ID 与显示名。
class Identity {
  static const _keyId = 'identity.id';
  static const _keyName = 'identity.name';

  static Future<DeviceInfo> load() async {
    final prefs = await SharedPreferences.getInstance();
    // 允许用环境变量覆盖设备 ID(仅内存生效,不写回存储)。
    // 用途:同一台机器上以不同 ID 多开实例做自测,或调试时标记实例。
    final envId = Platform.environment['LANCHAT_ID'];
    final envName = Platform.environment['LANCHAT_NAME'];
    if (envId != null && envId.isNotEmpty) {
      return DeviceInfo(
        id: envId,
        name: (envName != null && envName.isNotEmpty)
            ? envName
            : '$envId-${defaultSuffixFromHost()}',
        platform: defaultPlatform(),
      );
    }
    var id = prefs.getString(_keyId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_keyId, id);
    }
    var name = prefs.getString(_keyName);
    if (name == null || name.isEmpty) {
      name = defaultName();
      await prefs.setString(_keyName, name);
    }
    return DeviceInfo(id: id, name: name, platform: defaultPlatform());
  }

  static Future<void> saveName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyName, name);
  }

  static String defaultName() {
    String? hostName;
    try {
      hostName = Platform.localHostname;
    } catch (_) {}
    final base = (hostName != null && hostName.isNotEmpty)
        ? hostName.split('.').first
        : 'LanChat';
    return '$base-${defaultSuffixFromHost()}';
  }

  static String defaultSuffixFromHost() {
    String? hostName;
    try {
      hostName = Platform.localHostname;
    } catch (_) {}
    return (hostName != null && hostName.isNotEmpty && hostName.length > 5)
        ? hostName.substring(hostName.length - 3).toUpperCase()
        : 'LAN';
  }

  static String defaultPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}