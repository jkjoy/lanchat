import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 本地持久化：设备表 + 消息表（会话历史）。
///
/// Android/iOS 使用原生 sqflite；桌面端（Windows/macOS/Linux）使用
/// sqflite_common_ffi，二者通过统一的 [Database] 接口工作。
class LocalDatabase {
  static final LocalDatabase instance = LocalDatabase._();
  LocalDatabase._();

  Database? _db;

  Future<Database> open() async {
    if (_db != null) return _db!;

    // Windows/macOS/Linux 桌面平台在测试与运行均没有原生 sqlite，走 FFI。
    if (!Platform.isAndroid && !Platform.isIOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getDatabasesPath();
    await Directory(dir).create(recursive: true);
    _db = await databaseFactory.openDatabase(
      p.join(dir, 'lanchat.db'),
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE devices (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              platform TEXT NOT NULL,
              host TEXT,
              port INTEGER,
              last_seen INTEGER,
              online INTEGER DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY,
              peer_id TEXT NOT NULL,
              direction INTEGER NOT NULL,
              type TEXT NOT NULL,
              ts INTEGER NOT NULL,
              status TEXT NOT NULL,
              payload TEXT
            )
          ''');
          await db.execute(
              'CREATE INDEX idx_messages_peer_ts ON messages(peer_id, ts)');
          await db.execute(_createGroups);
        },
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 2) {
            await db.execute(_createGroups);
          }
        },
      ),
    );
    return _db!;
  }

  static const _createGroups = '''
    CREATE TABLE IF NOT EXISTS groups (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      owner TEXT NOT NULL,
      members TEXT NOT NULL,
      created INTEGER NOT NULL
    )
  ''';

  Future<void> upsertGroup(GroupRow row) async {
    final db = await open();
    await db.insert('groups', row.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<GroupRow>> loadGroups() async {
    final db = await open();
    final rows = await db.query('groups', orderBy: 'created DESC');
    return rows.map(GroupRow.fromMap).toList();
  }

  Future<void> deleteGroup(String id) async {
    final db = await open();
    await db.delete('groups', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> upsertDevice(PeerRow row) async {
    final db = await open();
    await db.insert('devices', row.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PeerRow>> loadDevices() async {
    final db = await open();
    final rows = await db.query('devices', orderBy: 'last_seen DESC');
    return rows.map(PeerRow.fromMap).toList();
  }

  Future<void> insertMessage(MessageRow row) async {
    final db = await open();
    await db.insert('messages', row.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<MessageRow>> loadMessages(String peerId,
      {int limit = 500}) async {
    final db = await open();
    final rows = await db.query(
      'messages',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      orderBy: 'ts ASC',
      limit: limit,
    );
    return rows.map(MessageRow.fromMap).toList();
  }

  Future<void> clearMessages(String peerId) async {
    final db = await open();
    await db.delete('messages', where: 'peer_id = ?', whereArgs: [peerId]);
  }

  /// 全文搜索消息(payload LIKE)。返回匹配行,按时间倒序。
  Future<List<MessageRow>> searchMessages(String keyword,
      {int limit = 50}) async {
    final db = await open();
    final like = '%$keyword%';
    final rows = await db.query(
      'messages',
      where: 'payload LIKE ?',
      whereArgs: [like],
      orderBy: 'ts DESC',
      limit: limit,
    );
    return rows.map(MessageRow.fromMap).toList();
  }
}

class PeerRow {
  final String id;
  final String name;
  final String platform;
  final String? host;
  final int? port;
  final int lastSeen;
  final int online;

  PeerRow({
    required this.id,
    required this.name,
    required this.platform,
    this.host,
    this.port,
    required this.lastSeen,
    required this.online,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'platform': platform,
        'host': host,
        'port': port,
        'last_seen': lastSeen,
        'online': online,
      };

  factory PeerRow.fromMap(Map<String, dynamic> m) => PeerRow(
        id: m['id'] as String,
        name: m['name'] as String,
        platform: m['platform'] as String? ?? '',
        host: m['host'] as String?,
        port: m['port'] as int?,
        lastSeen: m['last_seen'] as int? ?? 0,
        online: m['online'] as int? ?? 0,
      );
}

class MessageRow {
  final String id;
  final String peerId;
  final int direction; // 0=发出 1=收到
  final String type;
  final int ts;
  final String status; // pending/sent/delivered/read
  final String? payload; // 文本或 JSON 元数据

  MessageRow({
    required this.id,
    required this.peerId,
    required this.direction,
    required this.type,
    required this.ts,
    required this.status,
    this.payload,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'peer_id': peerId,
        'direction': direction,
        'type': type,
        'ts': ts,
        'status': status,
        'payload': payload,
      };

  factory MessageRow.fromMap(Map<String, dynamic> m) => MessageRow(
        id: m['id'] as String,
        peerId: m['peer_id'] as String,
        direction: m['direction'] as int? ?? 0,
        type: m['type'] as String? ?? 'chat',
        ts: m['ts'] as int? ?? 0,
        status: m['status'] as String? ?? 'sent',
        payload: m['payload'] as String?,
      );
}

/// 群组持久化行。
class GroupRow {
  final String id;
  final String name;
  final String owner;
  final List<String> members;
  final int created;

  GroupRow({
    required this.id,
    required this.name,
    required this.owner,
    required this.members,
    required this.created,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'owner': owner,
        'members': members.join(','),
        'created': created,
      };

  factory GroupRow.fromMap(Map<String, dynamic> m) => GroupRow(
        id: m['id'] as String,
        name: m['name'] as String,
        owner: m['owner'] as String,
        members: ((m['members'] as String?) ?? '').split(','),
        created: m['created'] as int? ?? 0,
      );
}