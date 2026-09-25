import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'file_transfer.dart';
import 'models.dart';

/// 消息到达时的回调：收到的封包 + 对端设备。
typedef MessageHandler = void Function(Envelope envelope, Peer peer);

/// WebSocket 双向连接管理。
///
/// 本机同时是 WS 服务器（接受其它设备连接）和 WS 客户端（主动连接其它
/// 设备）。握手规则保证收敛且无环：
/// - 拨号方向由设备 ID 字典序唯一决定（小者拨号），避免双向拨号抖动；
/// - 主动拨号方（outbound）连接建立后立即发一次自己的 `hello`；
/// - 被连接方（inbound）收到对方 `hello` 后注册连接并回发自己的 `hello`；
/// - 后续再收到同连接的 `hello` 只刷新设备信息，不再回发。
/// 连接保活用 WebSocket 原生 ping（15s，20s 无 pong 由客户端关闭并触发
/// 对端 onDone）；无需应用层空闲计时。
class ConnectionManager implements TransferSignaler {
  static const defaultPort = 53921;
  static const _pingInterval = Duration(seconds: 15);
  static const _connectTimeout = Duration(seconds: 6);

  final DeviceInfo self;
  final MessageHandler onEnvelope;
  final void Function(Peer peer, bool connected)? onStatusChanged;

  HttpServer? _server;
  int _serverPort = defaultPort;
  final Map<String, PeerConnection> _conns = {};
  final Map<String, DateTime> _lastDial = {};
  bool _closed = false;

  ConnectionManager({
    required this.self,
    required this.onEnvelope,
    this.onStatusChanged,
  });

  int get serverPort => _serverPort;

  bool isConnected(String peerId) => _conns.containsKey(peerId);

  /// 启动 WS 服务器。默认端口被占用时自动改用随机端口。
  /// [port] 指定时强制绑定该端口（测试用；绑定失败会抛异常）。
  Future<void> startServer({int? port}) async {
    final bindPort = port ?? defaultPort;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, bindPort);
    } on SocketException {
      if (port != null) rethrow;
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _serverPort = _server!.port;
    }
    _serverPort = _server!.port;
    _server!.listen(_onHttpRequest);
    debugPrint('[conn] ws server on :$_serverPort');
  }

  Future<void> close() async {
    _closed = true;
    for (final c in List.of(_conns.values)) {
      await c.channel.sink.close();
    }
    _conns.clear();
    await _server?.close(force: true);
    _server = null;
  }

  /// 尝试向对端发起连接。
  ///
  /// 拨号方向采用确定性规则避免双向拨号导致的连接抖动：仅当本机设备
  /// ID 字典序小于对端时才由我方拨号，否则等待对端拨号。失败静默，
  /// 由发现层稍后重试。
  Future<void> connectTo(Peer peer) async {
    if (_closed || _conns.containsKey(peer.id)) return;
    final host = peer.host;
    if (host == null) return;
    if (self.id.compareTo(peer.id) >= 0) {
      // 对端（字典序更小）负责拨号，本机仅作为服务器被动接受。
      return;
    }

    final last = _lastDial[peer.id];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastDial[peer.id] = DateTime.now();

    final uri = Uri.parse('ws://$host:${peer.port ?? defaultPort}/ws');
    try {
      final channel = IOWebSocketChannel.connect(
        uri,
        connectTimeout: _connectTimeout,
        pingInterval: _pingInterval,
      );
      debugPrint('[conn] dialing $host -> ${peer.id}');
      _attach(channel, peer: peer, outbound: true, viaHost: null);
    } catch (e) {
      debugPrint('[conn] dial $host failed: $e');
    }
  }

  /// 发送封包。返回是否写入成功。
  @override
  bool send(String peerId, Envelope envelope) {
    final c = _conns[peerId];
    if (c == null) return false;
    try {
      c.channel.sink.add(envelope.encode());
      return true;
    } catch (e) {
      debugPrint('[conn] send to $peerId failed: $e');
      return false;
    }
  }

  void _onHttpRequest(HttpRequest req) {
    if (req.headers.value('upgrade')?.toLowerCase() != 'websocket') {
      // 便于浏览器/工具做健康检查，非 WS 请求返回 200。
      req.response
        ..statusCode = HttpStatus.ok
        ..write('lanchat')
        ..close();
      return;
    }
    final host = req.connectionInfo?.remoteAddress.address;
    WebSocketTransformer.upgrade(req).then((ws) {
      debugPrint('[conn] accepted ws from $host');
      _attach(IOWebSocketChannel(ws), outbound: false, viaHost: host);
    }).catchError((e) {
      debugPrint('[conn] upgrade failed: $e');
    });
  }

void _attach(
    WebSocketChannel channel, {
    required bool outbound,
    Peer? peer,
    String? viaHost,
  }) {
    // 拨号方:连接建立后立即发送自己的 hello(仅一次)。
    // 注意:必须在 [WebSocketChannel.ready] 完成后再写,否则同步广播控制器的
    // 数据会在监听器挂载之前被丢弃。
    if (outbound && peer != null) {
      _conns[peer.id] = PeerConnection(
        peer: peer,
        channel: channel,
        outbound: true,
        helloSent: true,
      );
      channel.ready.then((_) {
        if (!_closed) {
          channel.sink.add(_hello(peer.id).encode());
        }
      }).catchError((Object e) {
        debugPrint('[conn] hello send failed: $e');
      });
      onStatusChanged?.call(peer, true);
    }

    channel.stream.listen(
      (data) {
        if (_closed) return;
        Envelope? env;
        try {
          final json = jsonDecode(data as String);
          if (json is Map<String, dynamic>) env = Envelope.fromJson(json);
        } catch (e) {
          debugPrint('[conn] bad frame: $e');
          return;
        }
        if (env == null) return;

        if (env.type == Envelope.typeHello) {
          _onHello(channel, env, outbound: outbound, viaHost: viaHost);
          return;
        }

        final registered = _conns[env.from];
        if (registered == null) {
          // 未完成握手就收到业务消息,忽略(对端会重发或重连)。
          debugPrint('[conn] frame from unregistered ${env.from}, ignored');
          return;
        }
        onEnvelope(env, registered.peer);
      },
      onDone: () {
        _unregister(channel, _peerIdFor(channel));
      },
      onError: (Object e) {
        debugPrint('[conn] stream error: $e');
        _unregister(channel, _peerIdFor(channel));
      },
    );
  }

  void _onHello(
    WebSocketChannel channel,
    Envelope env, {
    required bool outbound,
    String? viaHost,
  }) {
    final id = env.from;
    final existing = _conns[id];

    if (existing != null && existing.channel == channel) {
      // 握手已完成，这是对端重复/刷新消息：仅更新设备信息，不回发 hello。
      existing.peer
        ..name = (env.payload['name'] as String?) ?? existing.peer.name
        ..host = viaHost ?? existing.peer.host
        ..port =
            (env.payload['port'] as num?)?.toInt() ?? existing.peer.port
        ..lastSeen = DateTime.now();
      debugPrint('[conn] hello-refresh from $id (handshake complete)');
      onStatusChanged?.call(existing.peer, true);
      return;
    }

    // 新连接进来（或被替换）。
    if (existing != null) {
      debugPrint('[conn] replacing connection to $id');
      existing.channel.sink.close();
    }
    final p = Peer(
      id: id,
      name: (env.payload['name'] as String?) ?? 'unknown',
      platform: (env.payload['platform'] as String?) ?? 'unknown',
      host: viaHost ?? existing?.peer.host,
      port: (env.payload['port'] as num?)?.toInt() ?? existing?.peer.port,
      lastSeen: DateTime.now(),
      online: true,
    );
    _conns[id] = PeerConnection(
      peer: p,
      channel: channel,
      outbound: outbound,
      helloSent: !outbound,
    );
    debugPrint('[conn] registered $id (${outbound ? "outbound" : "inbound"})');
    onStatusChanged?.call(p, true);
    channel.sink.add(_hello(id).encode());
  }

  Envelope _hello(String to) => Envelope(
        type: Envelope.typeHello,
        from: self.id,
        to: to,
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'name': self.name,
          'platform': self.platform,
          'port': _serverPort,
        },
      );

  String? _peerIdFor(WebSocketChannel channel) {
    for (final entry in _conns.entries) {
      if (entry.value.channel == channel) return entry.key;
    }
    return null;
  }

  void _unregister(WebSocketChannel channel, String? peerId) {
    final id = peerId;
    if (id == null) return;
    final c = _conns[id];
    if (c == null || c.channel != channel) return;
    _conns.remove(id);
    c.peer.online = false;
    onStatusChanged?.call(c.peer, false);
    debugPrint('[conn] connection to $id closed');
  }

  static final _idGen = Uuid();
  static String _newId() => _idGen.v4();
}

class PeerConnection {
  Peer peer;
  final WebSocketChannel channel;
  final bool outbound;
  bool helloSent;

  PeerConnection({
    required this.peer,
    required this.channel,
    required this.outbound,
    required this.helloSent,
  });
}