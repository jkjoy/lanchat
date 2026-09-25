import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// 局域网设备发现。
///
/// 采用 UDP 广播通道:本机周期性向网内广播自身信息(设备 ID、名称、
/// 平台、WS 端口),同时监听网上的广播。双侧都运行本应用,因此发现是
/// 对等的,不依赖任何中心节点;广播地址兜底用 255.255.255.255。
class DeviceDiscovery {
  static const defaultAdvertisePort = 53920;

  final int advertisePort;
  final DeviceInfo _self;

  /// 对外监听的 WS 端口,随广播告诉对端,对端据此回连。
  final int serverPort;

  final StreamController<Peer> _found = StreamController<Peer>.broadcast();
  final StreamController<String> _gone = StreamController<String>.broadcast();

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _readSub;
  Timer? _announceTimer;
  Timer? _restartTimer;
  String? _lastError;
  bool _running = false;
  final Map<String, DateTime> _lastSeen = {};

  DeviceDiscovery(this._self, {required this.serverPort})
      : advertisePort = defaultAdvertisePort;

  /// 供测试注入自定义广播端口。
  DeviceDiscovery.withPort(this._self,
      {required this.serverPort, required this.advertisePort});

  Stream<Peer> get found => _found.stream;
  Stream<String> get gone => _gone.stream;
  String? get lastError => _lastError;

  /// 启动广播与监听。绑口失败等异常会自动重试。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      _socket?.close();
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        advertisePort,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;
      _socket = socket;

      // 组播互补:规避部分路由/系统对 255.255.255.255 的过滤。
      // 也加入回环接口,保证同一台机器多开实例也能互相发现(自测/调试)。
      try {
        final interfaces = await NetworkInterface.list(
            type: InternetAddressType.IPv4,
            includeLinkLocal: true,
            includeLoopback: true);
        for (final iface in interfaces) {
          socket.joinMulticast(InternetAddress('224.0.0.251'), iface);
        }
      } catch (e) {
        debugPrint('[discovery] multicast join skipped: $e');
      }

      _readSub = socket.listen(
        (event) {
          if (event == RawSocketEvent.read) _drain(socket);
        },
        onError: (Object e) {
          _lastError = e.toString();
          debugPrint('[discovery] socket error: $e');
        },
      );

      _announceTimer = Timer.periodic(const Duration(seconds: 3), (_) => _announce());
      _announce();

      debugPrint('[discovery] started, port=$advertisePort serverPort=$serverPort');
    } catch (e) {
      _running = false;
      _lastError = e.toString();
      debugPrint('[discovery] start failed: $e');
      _restartTimer?.cancel();
      _restartTimer = Timer(const Duration(seconds: 8), start);
    }
  }

  Future<void> stop() async {
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _readSub?.cancel();
    _readSub = null;
    _socket?.close();
    _socket = null;
  }

  /// 发送一条广播报文(定向 + 全局广播)。
  void _announce() {
    final s = _socket;
    if (s == null) return;
    final msg = utf8.encode(jsonEncode({
      't': 'lanchat:announce',
      'id': _self.id,
      'name': _self.name,
      'platform': _self.platform,
      'port': serverPort,
    }));

    // 直接发往本机回环(自测/本机多开) + 所有接口地址 + 255.255.255.255 全局广播。
    final targets = <InternetAddress>[InternetAddress.loopbackIPv4];
    NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
      includeLoopback: true,
    ).then((ifaces) {
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) targets.add(addr);
        }
      }
      for (final target in targets) {
        try {
          s.send(msg, target, advertisePort);
        } catch (e) {
          debugPrint('[discovery] send to $target failed: $e');
        }
      }
      try {
        s.send(msg, InternetAddress('255.255.255.255'), advertisePort);
      } catch (e) {
        debugPrint('[discovery] broadcast send failed: $e');
      }
      // 组播是跨机器发现的主通道：本机已加入组播组，组播回环可让同机多实例互见。
      try {
        s.send(msg, InternetAddress('224.0.0.251'), advertisePort);
      } catch (e) {
        debugPrint('[discovery] multicast send failed: $e');
      }
    });
  }

  void _drain(RawDatagramSocket s) {
    Datagram? datagram;
    while ((datagram = s.receive()) != null) {
      _handleDatagram(datagram!);
    }
  }

  void _handleDatagram(Datagram datagram) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(datagram.data));
    } catch (_) {
      return; // 非本协议的报文(mDNS 等),忽略。
    }
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['t'] != 'lanchat:announce') return;
    final id = decoded['id'] as String?;
    if (id == null || id == _self.id) return;

    final host = datagram.address.address;
    final name = (decoded['name'] as String?) ?? host;
    final platform = (decoded['platform'] as String?) ?? 'unknown';
    final port = (decoded['port'] as num?)?.toInt();

    _lastSeen[id] = DateTime.now();
    final peer = Peer(
      id: id,
      name: name,
      platform: platform,
      host: host,
      port: port,
      lastSeen: DateTime.now(),
      online: true,
    );
    _found.add(peer);
  }

  /// 清理超过 [timeout] 未再广播的设备(在线状态一致,15 秒一次由外层驱动)。
  void checkGone({Duration timeout = const Duration(seconds: 15)}) {
    final now = DateTime.now();
    final expired = <String>[];
    _lastSeen.forEach((id, ts) {
      if (now.difference(ts) > timeout) expired.add(id);
    });
    for (final id in expired) {
      _lastSeen.remove(id);
      _gone.add(id);
    }
  }
}