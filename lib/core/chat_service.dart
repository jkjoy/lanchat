import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'discovery.dart';
import 'connection.dart';
import 'database.dart';
import 'file_transfer.dart';
import 'group.dart';
import 'local_notifier.dart';
import 'pair_crypto.dart';
import 'voice_service.dart';

/// 聊天会话中的一条消息（UI 直接消费）。
@immutable
class ChatMessage {
  final String id;
  final String peerId;
  final bool outbound; // true=我发出
  final String text;
  final int ts;
  final String status; // pending/sent/delivered/read

  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.outbound,
    required this.text,
    required this.ts,
    required this.status,
  });

  ChatMessage copyWith({String? status}) => ChatMessage(
        id: id,
        peerId: peerId,
        outbound: outbound,
        text: text,
        ts: ts,
        status: status ?? this.status,
      );
}

/// 搜索结果(跨私聊/群聊)。
@immutable
class SearchResult {
  final String id;
  final String sessionId; // peerId 或 group-xxx 或 broadcast
  final bool outbound;
  final String text;
  final int ts;

  const SearchResult({
    required this.id,
    required this.sessionId,
    required this.outbound,
    required this.text,
    required this.ts,
  });

  bool get isGroup => sessionId.startsWith('group-');
}

/// 应用核心状态：设备发现、连接、消息收发、历史持久化，全部串联在此。
class ChatService {
  final DeviceInfo self;
  final LocalDatabase _db = LocalDatabase.instance;

late DeviceDiscovery _discovery;
  late ConnectionManager _conn;
  late FileTransferService _file;

  final Map<String, Peer> _peers = {};
  final ValueNotifier<List<Peer>> peersNotifier = ValueNotifier(const []);
  final ValueNotifier<String?> selectedPeerNotifier = ValueNotifier(null);

  /// 已加入的群，key = 群 ID。
  final Map<String, Group> _groups = {};
  final ValueNotifier<List<Group>> groupsNotifier = ValueNotifier(const []);

  /// 每个群的群消息，key = 群 ID。
  final Map<String, List<GroupMessage>> _groupSessions = {};

  /// 配对加密状态。
  final SessionCrypto crypto = SessionCrypto();
  final ValueNotifier<bool> cryptoEnabled = ValueNotifier(false);

  /// 本地通知(收到新消息时弹系统通知)。
  final LocalNotifier notifier = LocalNotifier.instance;

  /// 每个对端会话的消息缓存(内存),key 为对端设备 ID。
  final Map<String, List<ChatMessage>> _sessions = {};
  final ValueNotifier<List<ChatMessage>> messagesNotifier =
      ValueNotifier(const []);

  /// 会话有新消息/状态变化时递增,驱动会话列表按时间排序与红点显示。
  final ValueNotifier<int> sessionTick = ValueNotifier(0);

  /// 未读消息计数,key = 会话 ID(peerId/group-xxx/broadcast)。
  final Map<String, int> _unread = {};
  final ValueNotifier<int> totalUnread = ValueNotifier(0);
  final ValueNotifier<Map<String, int>> unreadMap = ValueNotifier(const {});

  /// 有未读的会话集(驱动列表红点)。
  Set<String> get sessionsWithUnread => _unread.keys.toSet();

  void _markUnread(String sessionId) {
    if (sessionId == selectedPeerNotifier.value) return;
    _unread[sessionId] = (_unread[sessionId] ?? 0) + 1;
    _emitUnread();
  }

  void clearUnread(String sessionId) {
    if (_unread.remove(sessionId) != null) _emitUnread();
  }

  void _emitUnread() {
    totalUnread.value =
        _unread.values.fold(0, (a, b) => a + b);
    unreadMap.value = Map.of(_unread);
  }

  /// 群发消息(广播):发给所有当前在线的设备。
  Future<void> broadcast(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final peers = _peers.values.where((p) => p.online).toList();
    if (peers.isEmpty) {
      debugPrint('[broadcast] 没有在线设备,群发丢弃');
      return;
    }
    final encrypted = crypto.enabled;
    final payload = encrypted ? await crypto.seal(t) : t;
    final env = Envelope(
      type: Envelope.typeBroadcast,
      from: self.id,
      to: 'all',
      id: const Uuid().v4(),
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: encrypted
          ? {
              'enc': true,
              'text': payload,
            }
          : {
              'text': payload,
            },
    );
    for (final p in peers) {
      _conn.send(p.id, env);
    }
    // 群发在自己设备上也记录一条(发送方视角)。
    final msg = ChatMessage(
      id: env.id,
      peerId: 'broadcast',
      outbound: true,
      text: t,
      ts: env.ts,
      status: 'sent',
    );
    _sessions.putIfAbsent('broadcast', () => []).add(msg);
    sessionTick.value++;
    debugPrint('[broadcast] 群发 ${peers.length} 台在线设备');
  }

  /// 发送设备列表与消息历史持久化相关。
  final VoiceService voice = VoiceService();

  StreamSubscription<Peer>? _foundSub;
  StreamSubscription<String>? _goneSub;
  Timer? _ticker;

  ChatService({required this.self});

  Future<void> start() async {
    await _db.open();

    // 初始化本地通知(仅移动/桌面支持的平台)。
    if (LocalNotifier.supported) {
      await notifier.init();
    }

    _conn = ConnectionManager(
      self: self,
      onEnvelope: _onEnvelope,
      onStatusChanged: _onStatusChanged,
    );
    await _conn.startServer();

    _file = FileTransferService(self: self, conn: _conn);
    await _file.start();

    // 恢复已保存的群组。
    final rows = await _db.loadGroups();
    for (final r in rows) {
      _groups[r.id] = Group(
        id: r.id,
        name: r.name,
        ownerId: r.owner,
        memberIds: r.members,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r.created),
        joined: true,
      );
    }
    _emitGroups();

    _discovery = DeviceDiscovery(self, serverPort: _conn.serverPort);
    _foundSub = _discovery.found.listen(_onPeerFound);
    _goneSub = _discovery.gone.listen(_onPeerGone);
    await _discovery.start();

    // 周期性检查在线状态与重连已发现的设备。
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
    _tick();
  }

  Future<void> shutdown() async {
    _ticker?.cancel();
    await _foundSub?.cancel();
    await _goneSub?.cancel();
    await _discovery.stop();
    await _file.close();
    await voice.dispose();
    await _conn.close();
  }

  FileTransferService get files => _file;

  /// 是否处于配对加密模式。
  bool get isEncrypted => cryptoEnabled.value;

  /// 用 [passphrase] 开启配对加密。成功后所有新消息加密传输。
  Future<void> enablePairing(String passphrase) async {
    await crypto.enable(passphrase.trim());
    cryptoEnabled.value = true;
  }

  /// 关闭配对加密(回到明文)。
  void disablePairing() {
    crypto.disable();
    cryptoEnabled.value = false;
  }

  Peer? peer(String id) => _peers[id];
  Peer? get selectedPeer {
    final id = selectedPeerNotifier.value;
    if (id == null) return null;
    if (id == 'broadcast' || id.startsWith('group-')) return null;
    return _peers[id];
  }

  /// 是否处于群发消息视图。
  bool get isBroadcastView => selectedPeerNotifier.value == 'broadcast';

  /// 当前选中的群（选中 group-* 会话时）。
  Group? get selectedGroup {
    final id = selectedPeerNotifier.value;
    if (id == null || !id.startsWith('group-')) return null;
    return _groups[id];
  }

  /// 全部已加入的群。
  List<Group> get groups => List.of(_groups.values)
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

List<ChatMessage> get currentMessages {
    final id = selectedPeerNotifier.value;
    if (id == null) return const [];
    // 群会话用独立的群消息流(转成 ChatMessage 供气泡复用)。
    if (id.startsWith('group-')) {
      return _groupSessions[id]
          ?.map((m) => ChatMessage(
                id: m.id,
                peerId: id,
                outbound: m.outbound,
                text: m.statusLabel.isNotEmpty
                    ? '${m.text}\n${m.statusLabel}'
                    : m.text,
                ts: m.ts,
                status: 'delivered',
              ))
          .toList() ??
          const [];
    }
    return _sessions[id] ?? const [];
  }

  /// 搜索全部本地消息(跨私聊/群聊)。返回含会话标识的结果。
  Future<List<SearchResult>> search(String keyword) async {
    final t = keyword.trim();
    if (t.isEmpty) return const [];
    final rows = await _db.searchMessages(t);
    return rows
        .map((r) => SearchResult(
              id: r.id,
              sessionId: r.peerId,
              outbound: r.direction == 0,
              text: r.payload ?? '',
              ts: r.ts,
            ))
        .toList();
  }

void select(String? peerId) {
    selectedPeerNotifier.value = peerId;
    _refreshMessages();
    // 进入会话清除未读。
    if (peerId != null) clearUnread(peerId);
    // 选中会话后,若有未送达消息且对端在线,尝试立即补发。
    if (peerId != null &&
        peerId != 'broadcast' &&
        !peerId.startsWith('group-')) {
      final p = _peers[peerId];
      if (p == null) return;
      _conn.isConnected(peerId)
          ? _flushPendingFor(peerId)
          : _conn.connectTo(p);
    }
  }

  /// 建群：邀请若干在线设备，创建者本地创建并广播 invitation。
  Future<Group?> createGroup(String name, List<String> memberIds) async {
    final t = name.trim();
    if (t.isEmpty) return null;
    final members = {self.id, ...memberIds}.toList();
    final group = Group(
      id: 'group-${const Uuid().v4().substring(0, 8)}',
      name: t,
      ownerId: self.id,
      memberIds: members,
      createdAt: DateTime.now(),
      joined: true,
    );

    _groups[group.id] = group;
    _persistGroup(group);
    _emitGroups();

    // 逐个通知被邀请设备。
    for (final mid in memberIds) {
      final peer = _peers[mid];
      if (peer == null || !peer.online) continue;
      _conn.send(mid, Envelope(
        type: Envelope.typeGroupInvite,
        from: self.id,
        to: mid,
        id: const Uuid().v4(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: group.toJson(),
      ));
    }
    debugPrint('[group] 创建 ${group.id}(${group.name}),成员 ${members.length}');
    return group;
  }

  /// 发送一条群消息给群内所有在线成员。
  Future<void> sendGroupMessage(String groupId, String text) async {
    final g = _groups[groupId];
    if (g == null) return;
    final t = text.trim();
    if (t.isEmpty) return;
    final encrypted = crypto.enabled;
    final payload = encrypted ? await crypto.seal(t) : t;
    final targetCount = g.memberIds.where((m) => m != self.id).length;
    final env = Envelope(
      type: Envelope.typeGroupChat,
      from: self.id,
      to: groupId,
      id: const Uuid().v4(),
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: encrypted
          ? {
              'enc': true,
              'text': payload,
            }
          : {
              'text': payload,
            },
    );
    var sentCount = 0;
    for (final mid in g.memberIds) {
      if (mid == self.id) continue;
      if (_conn.send(mid, env)) sentCount++;
    }
    // 本机也记录一条(发送方视角),附带送达统计。
    _appendGroupMessage(GroupMessage(
      id: env.id,
      groupId: groupId,
      senderId: self.id,
      senderName: self.name,
      text: t,
      ts: env.ts,
      outbound: true,
      deliveredCount: sentCount,
      totalCount: targetCount,
    ));
    debugPrint('[group] $groupId 群消息发送 $sentCount/$targetCount 位成员');
  }

  /// 退出群（通知所有成员并从本地删除）。
  Future<void> leaveGroup(String groupId) async {
    final g = _groups.remove(groupId);
    if (g == null) return;
    _groupSessions.remove(groupId);
    _db.deleteGroup(groupId);
    _emitGroups();
    if (selectedPeerNotifier.value == groupId) {
      select(null);
    }
    for (final mid in g.memberIds) {
      if (mid == self.id) continue;
      _conn.send(mid, Envelope(
        type: Envelope.typeGroupLeave,
        from: self.id,
        to: groupId,
        id: const Uuid().v4(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {'group_id': groupId, 'member': self.id},
      ));
    }
  }

  /// 发送一条文本消息。配对加密开启时自动加密 payload。
  Future<void> send(String peerId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final encrypted = crypto.enabled;
    final payload = encrypted ? await crypto.seal(t) : t;
    final env = Envelope(
      type: Envelope.typeChat,
      from: self.id,
      to: peerId,
      id: const Uuid().v4(),
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: encrypted
          ? {
              'enc': true,
              'text': payload,
            }
          : {
              'text': payload,
            },
    );
    final sent = _conn.send(peerId, env);

    final msg = ChatMessage(
      id: env.id,
      peerId: peerId,
      outbound: true,
      text: t,
      ts: env.ts,
      status: sent ? 'pending' : 'pending',
    );
    _sessions.putIfAbsent(peerId, () => []).add(msg);
    await _db.insertMessage(MessageRow(
      id: msg.id,
      peerId: peerId,
      direction: 0,
      type: 'chat',
      ts: msg.ts,
      status: sent ? 'pending' : 'pending',
      payload: t,
    ));
    if (peerId == selectedPeerNotifier.value) _refreshMessages();
    sessionTick.value++;
  }

/// 发送文件给对端。桌面端弹出系统文件选择器。
  Future<void> sendFile(String peerId, BuildContext context) async {
    final peer = _peers[peerId];
    if (peer == null) return;
    if (!_conn.isConnected(peerId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('对方离线,连接成功后再发送文件')),
      );
      return;
    }
    final picked = await FilePicker.pickFiles();
    final path = picked.isNotEmpty ? picked.first.path : null;
    if (path == null || path.isEmpty) return;
    if (context.mounted) {
      await sendFilePath(peerId, path);
    }
  }

  /// 直接按路径发送文件给对端(拖拽/粘贴入口复用)。
  Future<void> sendFilePath(String? peerId, String path) async {
    if (peerId == null) return;
    final peer = _peers[peerId];
    if (peer == null) return;
    if (!_conn.isConnected(peerId)) return;
    try {
      await _file.offerFile(peer, path);
    } catch (e) {
      debugPrint('[file] send $path failed: $e');
    }
  }

  /// 手动添加设备（mDNS/广播失效时的兜底入口）。
  Future<void> addManualPeer(String host) async {
    final existing = _peers.values.where((p) => p.host == host).toList();
    if (existing.isNotEmpty) {
      await _conn.connectTo(existing.first);
      return;
    }
    final peer = Peer(
      id: 'manual-${host.replaceAll('.', '-')}',
      name: host,
      platform: 'unknown',
      host: host,
      port: ConnectionManager.defaultPort,
      lastSeen: DateTime.now(),
      online: false,
    );
    _upsertPeer(peer);
    await _conn.connectTo(peer);
  }

  Future<void> renameSelf(String name) async {
    // 名称变更通过 Identity 持久化；重连已连接的设备以广播新名称。
    await Identity.saveName(name);
  }

  // ---------- 内部 ----------

  void _upsertPeer(Peer peer) {
    final existing = _peers[peer.id];
    if (existing != null) {
      existing
        ..name = peer.name
        ..platform = peer.platform
        ..host = peer.host ?? existing.host
        ..port = peer.port ?? existing.port
        ..lastSeen = peer.lastSeen
        ..online = peer.online || existing.online;
    } else {
      _peers[peer.id] = peer;
    }
    _emitPeers();
  }

  void _emitPeers() {
    final list = _peers.values.toList();
    // 在线优先，其次按名称。
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    peersNotifier.value = list;
  }

  void _refreshMessages() {
    messagesNotifier.value = currentMessages;
  }

  void _onPeerFound(Peer peer) {
    _upsertPeer(peer);
    _db.upsertDevice(PeerRow(
      id: peer.id,
      name: peer.name,
      platform: peer.platform,
      host: peer.host,
      port: peer.port,
      lastSeen: peer.lastSeen.millisecondsSinceEpoch,
      online: 1,
    ));
    _conn.connectTo(peer);
  }

  void _onPeerGone(String id) {
    final p = _peers[id];
    if (p == null) return;
    p.online = false;
    _emitPeers();
    _db.upsertDevice(PeerRow(
      id: p.id,
      name: p.name,
      platform: p.platform,
      host: p.host,
      port: p.port,
      lastSeen: p.lastSeen.millisecondsSinceEpoch,
      online: 0,
    ));
  }

  void _onStatusChanged(Peer peer, bool connected) {
    final p = _peers[peer.id];
    if (p == null) {
      _peers[peer.id] = peer;
    } else {
      p.online = connected;
      p.host = peer.host ?? p.host;
      p.port = peer.port ?? p.port;
    }
    _emitPeers();
    // 重连成功：补发该对端的 pending 消息（恢复会话上下文）。
    if (connected) {
      _flushPendingFor(peer.id);
    }
  }

  /// 补发对端 [peerId] 尚未送达的消息（pending 状态）。
  Future<void> _flushPendingFor(String peerId) async {
    final msgs = _sessions[peerId];
    if (msgs == null) return;
    var changed = false;
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (!m.outbound || m.status != 'pending') continue;
      final env = Envelope(
        type: Envelope.typeChat,
        from: self.id,
        to: peerId,
        id: m.id,
        ts: m.ts,
        payload: await _payloadFor(m.text),
      );
      final ok = _conn.send(peerId, env);
      if (ok) changed = true;
    }
    if (changed) {
      if (peerId == selectedPeerNotifier.value) _refreshMessages();
      sessionTick.value++;
debugPrint('[resend] 补发 pending 消息完成 ($peerId)');
  }
  }

  Future<Map<String, dynamic>> _payloadFor(String text) async {
    if (!crypto.enabled) return {'text': text};
    return {'enc': true, 'text': await crypto.seal(text)};
  }

  bool _isFileEnvelope(String type) =>
      type == Envelope.typeFileOffer ||
      type == Envelope.typeFileAccept ||
      type == Envelope.typeFileDecline ||
      type == Envelope.typeFileProgress ||
      type == Envelope.typeFileDone;

  void _onEnvelope(Envelope env, Peer peer) {
    // 文件信令交给传输服务处理。
    if (_isFileEnvelope(env.type)) {
      _file.handleEnvelope(env, peer);
      return;
    }
    switch (env.type) {
      case Envelope.typeChat:
        _onIncomingChat(env, peer);
        break;
      case Envelope.typeBroadcast:
        _onIncomingBroadcast(env, peer);
        break;
      case Envelope.typeReceipt:
        _onReceipt(env);
        break;
      case Envelope.typePairEnable:
        _onPairEnable(env);
        break;
      case Envelope.typeGroupInvite:
        _onGroupInvite(env, peer);
        break;
      case Envelope.typeGroupLeave:
        _onGroupLeave(env);
        break;
      case Envelope.typeGroupChat:
        _onGroupChat(env);
        break;
      case Envelope.typeGroupReceipt:
        _onGroupReceipt(env);
        break;
      default:
        break;
    }
  }

  /// 收到群邀请:自动加入(成员置为本地,joined=true)。
  void _onGroupInvite(Envelope env, Peer peer) {
    final j = env.payload;
    if (j.isEmpty) return;
    final group = Group.fromJson(j);
    final existing = _groups[group.id];
    if (existing == null) {
      _groups[group.id] = group;
      _persistGroup(group);
      _emitGroups();
      debugPrint('[group] 加入 ${group.id}(${group.name})');
    }
  }

  /// 有成员退出:从群成员移除;若群为空(创建者退出)删除本地群。
  void _onGroupLeave(Envelope env) {
    final gid = env.payload['group_id'] as String?;
    final member = env.payload['member'] as String?;
    if (gid == null) return;
    final g = _groups[gid];
    if (g == null) return;
    if (member == null) return;
    final next = g.memberIds.where((m) => m != member).toList();
    if (next.isEmpty) {
      _groups.remove(gid);
      _groupSessions.remove(gid);
      _db.deleteGroup(gid);
      if (selectedPeerNotifier.value == gid) select(null);
    } else {
      _groups[gid] = g.copyWith(memberIds: next);
      _persistGroup(_groups[gid]!);
    }
    _emitGroups();
  }

/// 收到群消息:归属到对应群会话(同时写入 messages 表供搜索)。收到后向群所有成员发已读回执。
  void _onGroupChat(Envelope env) {
    final gid = env.to;
    final g = _groups[gid];
    if (g == null) return; // 未加入的群,忽略。
    final enc = env.payload['enc'] == true;
    final raw = env.payload['text'] as String? ?? '';
    // 异步解密后落盘(加密开启时)。
    _resolveGroupText(raw, enc).then((text) {
      if (text == null) {
        debugPrint('[group] 解密失败来自 ${env.from}');
        return;
      }
      final senderName = peer(env.from)?.name ?? env.from;
      final gm = GroupMessage(
        id: env.id,
        groupId: gid,
        senderId: env.from,
        senderName: senderName,
        text: text,
        ts: env.ts,
        outbound: false,
      );
      _appendGroupMessage(gm);
      // 群消息也入库,使跨会话搜索可召回。
      _db.insertMessage(MessageRow(
        id: gm.id,
        peerId: gid,
        direction: 1,
        type: 'group_chat',
        ts: gm.ts,
        status: 'delivered',
        payload: '(${gm.senderName}) ${gm.text}',
      ));
      if (selectedPeerNotifier.value == gid) _refreshMessages();
      sessionTick.value++;
      _markUnread(gid);
      _notifyIncoming('${g.name} . ${senderName}', text);

      // 回送群已读回执:向其他成员广播本机已送达+已读该消息。
      if (env.from != self.id) {
        _conn.send(env.from, Envelope(
          type: Envelope.typeGroupReceipt,
          from: self.id,
          to: env.from,
          id: const Uuid().v4(),
          ts: DateTime.now().millisecondsSinceEpoch,
          payload: {'group_id': gid, 'ack': env.id},
        ));
      }
    });
  }

  /// 收到群消息回执:更新发送方视角的送达计数。
  void _onGroupReceipt(Envelope env) {
    final gid = env.payload['group_id'] as String?;
    final ack = env.payload['ack'] as String?;
    if (gid == null || ack == null) return;
    final msgs = _groupSessions[gid];
    if (msgs == null) return;
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.id == ack && m.outbound && m.deliveredCount < m.totalCount) {
        msgs[i] = m.copyWith(deliveredCount: m.deliveredCount + 1);
        if (selectedPeerNotifier.value == gid) _refreshMessages();
        break;
      }
    }
  }

  Future<String?> _resolveGroupText(String raw, bool enc) async {
    if (!enc || !crypto.enabled) return raw;
    return crypto.open(raw);
  }

  void _onPairEnable(Envelope env) {
    // 对端声明它的会话已开启加密。凡 type 是 chat 的 payload.text 已加密。
    // 这里仅作状态提示，真正的解密发生在渲染/存储时。
    debugPrint('[pair] peer ${env.from} 已开启配对加密');
  }

void _onIncomingChat(Envelope env, Peer peer) async {
    String text = env.payload['text'] as String? ?? '';
    // 若本机已开启配对加密且对方用密文发送,用会话密钥解密。
    // 未开启时直接使用原文(兼容旧版明文)。
    if (crypto.enabled && env.payload['enc'] == true) {
      final clear = await crypto.open(text);
      if (clear == null) {
        debugPrint('[pair] 解密失败:来自 ${peer.id} 的消息无法解密');
        return; // 密钥不匹配,忽略该消息避免脏数据。
      }
      text = clear;
    }

    final msg = ChatMessage(
      id: env.id,
      peerId: peer.id,
      outbound: false,
      text: text,
      ts: env.ts,
      status: 'delivered',
    );
    _sessions.putIfAbsent(peer.id, () => []).add(msg);
    _db.insertMessage(MessageRow(
      id: msg.id,
      peerId: peer.id,
      direction: 1,
      type: 'chat',
      ts: msg.ts,
      status: 'delivered',
      payload: text,
    ));
if (peer.id == selectedPeerNotifier.value) _refreshMessages();
    sessionTick.value++;
    _markUnread(peer.id);
    _notifyIncoming(peer.name, text);

    // 回送回执。若连接刚断,静默失败即可。
    _conn.send(peer.id, Envelope.receipt(from: self.id, to: peer.id, ackId: env.id));
  }

  /// 收到群发消息:归属到"群发"会话视图(peerId = broadcast)。
  void _onIncomingBroadcast(Envelope env, Peer peer) async {
    String text = env.payload['text'] as String? ?? '';
    if (crypto.enabled && env.payload['enc'] == true) {
      final clear = await crypto.open(text);
      if (clear == null) {
        debugPrint('[broadcast] 解密失败:来自 ${peer.id} 的群发无法解密');
        return;
      }
      text = clear;
    }
    final msg = ChatMessage(
      id: env.id,
      peerId: 'broadcast',
      outbound: false,
      text: '(${peer.name}) $text',
      ts: env.ts,
      status: 'delivered',
    );
    _sessions.putIfAbsent('broadcast', () => []).add(msg);
    _db.insertMessage(MessageRow(
      id: msg.id,
      peerId: 'broadcast',
      direction: 1,
      type: 'chat',
      ts: msg.ts,
      status: 'delivered',
      payload: msg.text,
    ));
    sessionTick.value++;
    _markUnread('broadcast');
    _notifyIncoming('群发消息', text);
  }

  /// 收到新消息时弹出系统通知(仅小窗/后台时弹,前台不打扰)。
  void _notifyIncoming(String title, String body) {
    if (LocalNotifier.supported) {
      notifier.show(title, body);
    }
  }

  void _onReceipt(Envelope env) {
    final ackId = env.payload['ack'] as String?;
    if (ackId == null) return;
    // 更新内存与数据库中的状态。
    String? changedPeerId;
    for (final entry in _sessions.entries) {
      final list = entry.value;
      for (var i = 0; i < list.length; i++) {
        if (list[i].id == ackId && list[i].outbound) {
          list[i] = list[i].copyWith(status: 'delivered');
          changedPeerId = entry.key;
          break;
        }
      }
    }
    if (changedPeerId != null) {
      if (changedPeerId == selectedPeerNotifier.value) _refreshMessages();
      sessionTick.value++;
    }
  }

void _tick() {
    _discovery.checkGone();
    // 对发现的设备主动重连(幂等,连接已存在时内部直接跳过)。
    for (final p in _peers.values) {
      if (p.online) continue;
      _conn.connectTo(p);
    }
  }

  // ---------- 群组辅助 ----------

  void _emitGroups() {
    final list = List.of(_groups.values)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    groupsNotifier.value = list;
  }

  void _persistGroup(Group g) {
    _db.upsertGroup(GroupRow(
      id: g.id,
      name: g.name,
      owner: g.ownerId,
      members: g.memberIds,
      created: g.createdAt.millisecondsSinceEpoch,
    ));
  }

  void _appendGroupMessage(GroupMessage m) {
    _groupSessions.putIfAbsent(m.groupId, () => []).add(m);
    sessionTick.value++;
  }
}