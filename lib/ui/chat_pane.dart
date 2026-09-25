import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';

import '../core/chat_service.dart';
import '../core/group.dart';
import '../core/models.dart';

/// 会话气泡与输入栏(桌面/移动端共用)。
class ChatPane extends StatelessWidget {
  final ChatService service;

  const ChatPane({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    // 选中会话变化时整体重绘(标题栏/输入栏/列表的显隐都依赖选中态)。
    return ValueListenableBuilder<String?>(
      valueListenable: service.selectedPeerNotifier,
      builder: (context, _, _) {
        final peer = service.selectedPeer;
        final isBroadcast = peer == null && service.isBroadcastView;
        final isGroup = service.selectedGroup != null;
        final headerPeer = isGroup ? null : peer;
        final composerPeerId = isGroup
            ? service.selectedGroup!.id
            : (isBroadcast ? 'broadcast' : peer?.id);

        // 桌面端:整个会话窗格作为拖放区,拖入文件即发送。
        return DropTarget(
          onDragDone: (details) {
            final files = details.files;
            if (files.isEmpty) return;
            for (final item in files) {
              final p = item.path;
              if (File(p).existsSync()) {
                service.sendFilePath(peer?.id, p);
              }
            }
          },
          child: Column(
            children: [
              if (headerPeer != null || isBroadcast || isGroup)
                _ChatHeader(peer: headerPeer, group: service.selectedGroup),
              const Divider(height: 1),
              Expanded(
                child: (peer == null && !isBroadcast && !isGroup)
                    ? const _EmptyState()
                    : _MessageList(service: service),
              ),
              (headerPeer != null || isBroadcast || isGroup)
                  ? _Composer(
                      service: service,
                      peerId: composerPeerId ?? '',
                      broadcast: isBroadcast,
                      group: isGroup,
                    )
                  : const SizedBox.shrink(),
            ],
          ),
        );
      },
    );
  }
}

class _ChatHeader extends StatelessWidget {
  final Peer? peer;
  final Group? group;

  const _ChatHeader({this.peer, this.group});

  @override
  Widget build(BuildContext context) {
    final isBroadcast = peer == null && group == null;
    final isGroup = group != null;
    final name = isGroup
        ? group!.name
        : (isBroadcast ? '群发消息' : (peer?.name ?? ''));
    final online = isBroadcast || isGroup ? true : (peer?.online ?? false);
    final memberInfo = isGroup ? '${group!.memberIds.length} 人' : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          // 会话头像:群用群图标,群发用喇叭,私聊用首字。
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.tertiary,
                ],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: isBroadcast
                  ? const Icon(Icons.campaign_rounded,
                      color: Colors.white, size: 20)
                  : isGroup
                      ? const Icon(Icons.group_rounded,
                          color: Colors.white, size: 20)
                      : Text(
                          name.isEmpty ? '?' : name[0].toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: online ? const Color(0xFF34C759) : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      memberInfo ?? (online ? '在线' : '离线'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  final ChatService service;

  const _MessageList({required this.service});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ChatMessage>>(
      valueListenable: service.messagesNotifier,
      builder: (context, messages, _) {
        if (messages.isEmpty) {
          return const Center(
            child: Text('还没有消息，说点什么吧', style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          reverse: true,
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg = messages[messages.length - 1 - index];
            return _Bubble(msg: msg);
          },
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage msg;

  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = msg.outbound;

    // 不对称圆角:靠近发送侧的一角收窄,形成方向感。
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 5),
      bottomRight: Radius.circular(mine ? 5 : 18),
    );

    final BoxDecoration decoration = mine
        ? BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [scheme.primary, scheme.primary.withValues(alpha: 0.82)],
            ),
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.28),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          )
        : BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
            borderRadius: radius,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          );

    final fg = mine ? Colors.white : scheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: decoration,
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            SelectableText(
              msg.text,
              style: TextStyle(
                  color: fg, fontSize: 15, height: 1.35, letterSpacing: 0.1),
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmtTime(msg.ts),
                  style: TextStyle(
                      fontSize: 10,
                      color: mine
                          ? Colors.white.withValues(alpha: 0.75)
                          : fg.withValues(alpha: 0.45)),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Icon(
                    msg.status == 'delivered'
                        ? Icons.done_all_rounded
                        : Icons.done_rounded,
                    size: 14,
                    color: msg.status == 'delivered'
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.6),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

class _Composer extends StatefulWidget {
  final ChatService service;
  final String peerId;
  final bool broadcast;
  final bool group;

  const _Composer({
    required this.service,
    required this.peerId,
    this.broadcast = false,
    this.group = false,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final TextEditingController _controller = TextEditingController();
  bool _recording = false;

  Future<void> _toggleRecord() async {
    if (_recording) {
      // 停止录音并发送。
      final path = await widget.service.voice.stop();
      setState(() => _recording = false);
      if (path != null && File(path).existsSync()) {
        await widget.service.sendFilePath(widget.peerId, path);
      }
      return;
    }
    final ok = await widget.service.voice.start();
    if (ok) {
      setState(() => _recording = true);
    }
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    if (widget.broadcast) {
      widget.service.broadcast(text);
    } else if (widget.group) {
      widget.service.sendGroupMessage(widget.peerId, text);
    } else {
      widget.service.send(widget.peerId, text);
    }
    _controller.clear();
  }

  /// 粘贴剪贴板中的图片并发送(桌面/Android 通用)。
  Future<void> _pasteImage() async {
    final image = await Pasteboard.image;
    if (image == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板中没有图片')),
        );
      }
      return;
    }
    try {
      final dir = Directory.systemTemp;
      final path = '${dir.path}/lanchat_paste_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(image);
      await widget.service.sendFilePath(widget.peerId, path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('粘贴发送失败: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

@override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '发送文件',
                onPressed: () =>
                    widget.service.sendFile(widget.peerId, context),
                icon: const Icon(Icons.attach_file_rounded),
              ),
              IconButton(
                tooltip: '从相册选择图片发送',
                onPressed: () => widget.service.sendImage(widget.peerId),
                icon: const Icon(Icons.photo_library_outlined),
              ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: '输入消息...',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: _recording ? '停止录音并发送' : '录音发送',
                onPressed: _toggleRecord,
                icon: Icon(
                  _recording ? Icons.stop_circle_rounded : Icons.mic_rounded,
                  color: _recording ? scheme.error : null,
                ),
              ),
              IconButton(
                tooltip: '粘贴图片发送',
                onPressed: _pasteImage,
                icon: const Icon(Icons.content_paste_rounded),
              ),
              const SizedBox(width: 2),
              // 渐变发送按钮。
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: _send,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          scheme.primary,
                          scheme.primary.withValues(alpha: 0.8),
                        ],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.send_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 渐变圆环 + 中心图标,替代单色大图标。
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: 0.16),
                  scheme.tertiary.withValues(alpha: 0.10),
                ],
              ),
            ),
            child: Icon(Icons.wifi_tethering_rounded,
                size: 44, color: scheme.primary.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 18),
          Text('选择一台设备开始聊天',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            '同一局域网内打开 LanChat 的设备会自动出现\n也可以点击 + 手动输入对方 IP',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }
}