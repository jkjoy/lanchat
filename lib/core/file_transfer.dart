import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'platform_storage.dart';

import 'models.dart';

enum TransferDirection { out, in_ }

enum TransferStatus { offer, transferring, done, failed, declined }

@immutable
class TransferView {
  final String id;
  final String peerId;
  final String peerName;
  final String name;
  final TransferDirection direction;
  final int size;
  final int received;
  final TransferStatus status;

  const TransferView({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.name,
    required this.direction,
    required this.size,
    required this.received,
    required this.status,
  });

  double get progress =>
      size <= 0 ? 0 : (received / size).clamp(0.0, 1.0).toDouble();

  bool get isIncoming => direction == TransferDirection.in_;

  TransferView copyWith({
    int? received,
    TransferStatus? status,
  }) =>
      TransferView(
        id: id,
        peerId: peerId,
        peerName: peerName,
        name: name,
        direction: direction,
        size: size,
        received: received ?? this.received,
        status: status ?? this.status,
      );
}

/// 文件传输：通过独立的 HTTP 通道（带 Range 断点续传）发送字节，
/// 用 WebSocket 信封做信令（offer / accept / progress / done）。
///
/// 发送方在本机起一个只服务本传输的文件 HTTP 服务；接收方用 HttpClient
/// 分块拉取并落盘，进度通过 WS `file_progress` 回传给发送方。
abstract class TransferSignaler {
  bool send(String peerId, Envelope envelope);
}

class FileTransferService {
  static const defaultPort = 53922;
  static const _chunkSize = 256 * 1024;

  final DeviceInfo self;
  final TransferSignaler conn;

  final ValueNotifier<List<TransferView>> transfersNotifier =
      ValueNotifier(const []);

  /// 收到新的 incoming offer 时（UI 据此弹接收/拒绝）。
  final StreamController<TransferView> incomingOffers = StreamController.broadcast();

  HttpServer? _server;
  int _serverPort = defaultPort;
  Directory? _saveDir;

  final Map<String, _Outgoing> _outgoing = {};
  final Map<String, _Incoming> _incoming = {};

  FileTransferService({required this.self, required this.conn});

  /// 每次下载完成后对外通知,便于调用方将文件复制到公共目录(Android 相册/Downloads 等)。
  void Function(String sourcePath, String name)? onCompleted;

  int get serverPort => _serverPort;

  Future<void> start({int? port, Directory? saveRoot}) async {
    try {
      _server = await HttpServer.bind(
          InternetAddress.anyIPv4, port ?? defaultPort);
    } on SocketException {
      if (port != null) rethrow;
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _serverPort = _server!.port;
    _server!.listen(_onHttpRequest);
    debugPrint('[file] http server on :$_serverPort');

    if (saveRoot != null) {
      _saveDir = saveRoot;
    } else {
      final docs = await getApplicationDocumentsDirectory();
      _saveDir = Directory(p.join(docs.path, 'lanchat_files'));
    }
    await _saveDir!.create(recursive: true);
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 桌面向 UI 暴露保存目录（展示已接收文件位置）。
  Future<Directory?> get saveDirectory async => _saveDir;

  /// 供 UI 判断:接收的文件存放于应用文档目录。
  String? get saveDirPath => _saveDir?.path;

  /// 发起发送一个文件给 [peer]。返回传输 ID。
  Future<String> offerFile(Peer peer, String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('文件不存在', path);
    }
    final size = await file.length();
    final name = p.basename(path);
    final id = const Uuid().v4();

    _outgoing[id] = _Outgoing(
      file: file,
      size: size,
      name: name,
      path: path,
      transferId: id,
    );
    _upsertView(TransferView(
      id: id,
      peerId: peer.id,
      peerName: peer.name,
      name: name,
      direction: TransferDirection.out,
      size: size,
      received: 0,
      status: TransferStatus.offer,
    ));

    conn.send(peer.id, Envelope(
      type: Envelope.typeFileOffer,
      from: self.id,
      to: peer.id,
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {
        'transfer_id': id,
        'name': name,
        'size': size,
        'port': _serverPort,
      },
    ));
    return id;
  }

  /// 接收方接受一个 incoming offer，开始下载。
  Future<void> acceptTransfer(String id, Peer peer) async {
    final inc = _incoming[id];
    if (inc == null) return;
    inc.accepted = true;
    _upsertView(inc.toView().copyWith(status: TransferStatus.transferring));

    conn.send(peer.id, Envelope(
      type: Envelope.typeFileAccept,
      from: self.id,
      to: peer.id,
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {'transfer_id': id},
    ));
    try {
      await _download(id, peer);
    } catch (e) {
      debugPrint('[file] download failed: $e');
      inc.done();
      _upsertView(inc.toView().copyWith(status: TransferStatus.failed));
    }
  }

  /// 接收方拒绝。
  void declineTransfer(String id, Peer peer) {
    final inc = _incoming.remove(id);
    if (inc == null) return;
    inc.done();
    _upsertView(inc.toView().copyWith(status: TransferStatus.declined));
    conn.send(peer.id, Envelope(
      type: Envelope.typeFileDecline,
      from: self.id,
      to: peer.id,
      id: _newId(),
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: {'transfer_id': id},
    ));
  }

  /// 处理通过 WS 到达的文件信令。
  void handleEnvelope(Envelope env, Peer peer) {
    switch (env.type) {
      case Envelope.typeFileOffer:
        _onOffer(env, peer);
        break;
      case Envelope.typeFileAccept:
        _onAccept(env, peer);
        break;
      case Envelope.typeFileDecline:
        _onDecline(env, peer);
        break;
      case Envelope.typeFileProgress:
        _onProgress(env);
        break;
      case Envelope.typeFileDone:
        _onDone(env);
        break;
      default:
        break;
    }
  }

  // ---------- 信令处理 ----------

  void _onOffer(Envelope env, Peer peer) {
    final id = env.payload['transfer_id'] as String?;
    if (id == null) return;
    final name = (env.payload['name'] as String?) ?? 'file';
    final size = (env.payload['size'] as num?)?.toInt() ?? 0;
    final port = (env.payload['port'] as num?)?.toInt();

    // 同一传输重新 offer(断线重连后):若已有部分文件则续传。
    final existing = _incoming[id];
    final targetPath = p.join(_saveDir!.path, name);
    final partial = File('$targetPath.part');
    int base = 0;
    if (existing == null) {
      if (partial.existsSync()) base = partial.lengthSync();
      _incoming[id] = _Incoming(
        id: id,
        name: name,
        size: size,
        peer: peer,
        host: peer.host,
        port: port,
        targetPath: targetPath,
        partial: partial,
        base: base,
      );
    }

    final view = _Incoming(
      id: id,
      name: name,
      size: size,
      peer: peer,
      host: peer.host,
      port: port,
      targetPath: targetPath,
      partial: partial,
      base: base,
    ).toView();

    if (base > 0 && base < size) {
      // 有续传基础，立即恢复传输，不再打扰 UI。
      _incoming[id]!.base = base;
      _incoming[id]!.accepted = true;
      _upsertView(view.copyWith(status: TransferStatus.transferring));
      // 通知对端继续（无需 accept，直接开始）。
      conn.send(peer.id, Envelope(
        type: Envelope.typeFileAccept,
        from: self.id,
        to: peer.id,
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {'transfer_id': id, 'from': base},
      ));
      _download(id, peer);
    } else {
      _upsertView(view);
      incomingOffers.add(view);
    }
  }

  void _onAccept(Envelope env, Peer peer) {
    final id = env.payload['transfer_id'] as String?;
    if (id == null) return;
    final out = _outgoing[id];
    if (out == null) return;
    out.accepted = true;
    _upsertView(out.toView(status: TransferStatus.transferring));
  }

  void _onDecline(Envelope env, Peer peer) {
    final id = env.payload['transfer_id'] as String?;
    if (id == null) return;
    final out = _outgoing.remove(id);
    if (out == null) return;
    _upsertView(out.toView(status: TransferStatus.declined));
  }

  void _onProgress(Envelope env) {
    final id = env.payload['transfer_id'] as String?;
    final received = (env.payload['received'] as num?)?.toInt();
    if (id == null || received == null) return;
    final out = _outgoing[id];
    if (out == null) return;
    _upsertView(out.toView(received: received));
  }

  void _onDone(Envelope env) {
    final id = env.payload['transfer_id'] as String?;
    final out = _outgoing.remove(id);
    if (out == null) return;
    _upsertView(out.toView(received: out.size, status: TransferStatus.done));
  }

  // ---------- HTTP ----------

  void _onHttpRequest(HttpRequest req) {
    final segments = req.uri.pathSegments;
    if (segments.length != 2) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.close();
      return;
    }
    final id = segments[1];
    final out = _outgoing[id];
    if (out == null || !out.accepted) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.close();
      return;
    }
    // Range: bytes=start- 支持续传（本地读取从头开始也行，由接收端丢弃）。
    int start = 0;
    final range = req.headers.value('range');
    if (range != null && range.startsWith('bytes=')) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) start = int.tryParse(m.group(1)!) ?? 0;
    }
    _serveChunked(out, req.response, start);
  }

  Future<void> _serveChunked(_Outgoing out, HttpResponse res, int start) async {
    try {
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType.binary;
      res.headers.set('Content-Disposition',
          'attachment; filename="${_safeHeader(out.name)}"');
      final raf = await out.file.open();
      try {
        await raf.setPosition(start);
        final byteBuf = Uint8List(_chunkSize);
        while (true) {
          final n = await raf.readInto(byteBuf, 0, _chunkSize);
          if (n <= 0) break;
          res.add(byteBuf.sublist(0, n));
        }
      } finally {
        await raf.close();
      }
      await res.close();
      debugPrint('[file] served ${out.name} (from $start)');
    } catch (e) {
      debugPrint('[file] serve failed: $e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  // ---------- 下载（接收方） ----------

  Future<void> _download(String id, Peer peer) async {
    final inc = _incoming[id];
    if (inc == null) return;
    final host = inc.host ?? peer.host;
    final port = inc.port;
    if (host == null || port == null) throw StateError('缺少对端地址');

    final client = HttpClient();
    try {
      final url = Uri.parse('http://$host:$port/file/$id');
      final req = await client.getUrl(url);
      if (inc.base > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=${inc.base}-');
      }
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${res.statusCode}');
      }

      final sink = inc.partial.openWrite(mode: FileMode.append);
      int received = inc.base;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        inc.received = received;
        if (received - (inc._lastReport ?? 0) >= 512 * 1024 ||
            received >= inc.size) {
          inc._lastReport = received;
          _upsertView(inc.toView());
          conn.send(peer.id, Envelope(
            type: Envelope.typeFileProgress,
            from: self.id,
            to: peer.id,
            id: _newId(),
            ts: DateTime.now().millisecondsSinceEpoch,
            payload: {'transfer_id': id, 'received': received},
          ));
        }
      }
      await sink.flush();
      await sink.close();
      await inc.partial.rename(inc.targetPath);
      inc.done();
      _upsertView(inc.toView().copyWith(status: TransferStatus.done));
      // 下载完成:尝试复制到平台公共目录(Android Downloads/相册、桌面 Downloads)。
      try {
        final publicPath =
            await PlatformStorage.saveToPublic(inc.targetPath, inc.name);
        debugPrint('[file] 已保存到公共目录: $publicPath');
      } catch (e) {
        debugPrint('[file] 保存到公共目录失败(保留应用目录): $e');
      }
      conn.send(peer.id, Envelope(
        type: Envelope.typeFileDone,
        from: self.id,
        to: peer.id,
        id: _newId(),
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {'transfer_id': id},
      ));
    } finally {
      client.close(force: true);
    }
  }

  // ---------- 工具 ----------

  void _upsertView(TransferView view) {
    final list = List<TransferView>.from(transfersNotifier.value);
    final i = list.indexWhere((v) => v.id == view.id);
    if (i >= 0) {
      list[i] = view;
    } else {
      list.insert(0, view);
    }
    transfersNotifier.value = list;
  }

  static String _safeHeader(String s) => s.replaceAll(RegExp(r'[\\"\r\n]'), '_');

  static final _idGen = Uuid();
  static String _newId() => _idGen.v4();
}

class _Outgoing {
  final File file;
  final int size;
  final String name;
  final String path;
  final String transferId;
  bool accepted = false;

  _Outgoing({
    required this.file,
    required this.size,
    required this.name,
    required this.path,
    required this.transferId,
  });

  TransferView toView({int received = 0, TransferStatus status = TransferStatus.offer, String peerId = '', String peerName = ''}) =>
      TransferView(
        id: transferId,
        peerId: peerId,
        peerName: peerName,
        name: name,
        direction: TransferDirection.out,
        size: size,
        received: received,
        status: status,
      );
}

class _Incoming {
  final String id;
  final String name;
  final int size;
  final Peer peer;
  final String? host;
  final int? port;
  final String targetPath;
  final File partial;
  int base;
  int received = 0;
  bool accepted = false;
  int? _lastReport;

  _Incoming({
    required this.id,
    required this.name,
    required this.size,
    required this.peer,
    required this.host,
    required this.port,
    required this.targetPath,
    required this.partial,
    required this.base,
  }) : received = base;

  void done() {
    // 清理部分文件。
    if (partial.existsSync() && base == 0 && received == 0) {
      try {
        partial.deleteSync();
      } catch (_) {}
    }
  }

  TransferView toView() => TransferView(
        id: id,
        peerId: peer.id,
        peerName: peer.name,
        name: name,
        direction: TransferDirection.in_,
        size: size,
        received: received,
        status: accepted
            ? TransferStatus.transferring
            : TransferStatus.offer,
      );
}