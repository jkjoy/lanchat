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
    final memberInfo = isGroup ? '${group!.memberIds.length} 人' : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (isBroadcast)
            const Icon(Icons.campaign_outlined, size: 18)
          else if (isGroup)
            const Icon(Icons.group_outlined, size: 18),
          if (isBroadcast || isGroup) const SizedBox(width: 6),
          Text(name,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  )),
          if (memberInfo != null) ...[
            const SizedBox(width: 8),
            Text(memberInfo,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.primary)),
          ],
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
    final bg = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(msg.text, style: TextStyle(color: fg, fontSize: 15)),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmtTime(msg.ts),
                  style: TextStyle(
                      fontSize: 10, color: fg.withValues(alpha: 0.6)),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Icon(msg.status == 'delivered' ? Icons.done_all : Icons.done,
                      size: 13,
                      color: msg.status == 'delivered'
                          ? scheme.primary
                          : fg.withValues(alpha: 0.5)),
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            IconButton(
              tooltip: '发送文件',
              onPressed: () => widget.service.sendFile(widget.peerId, context),
              icon: const Icon(Icons.attach_file),
            ),
            const SizedBox(width: 4),
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
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: _recording ? '停止录音并发送' : '按住录音发送',
              onPressed: _toggleRecord,
              icon: Icon(
                _recording ? Icons.stop_circle : Icons.mic,
                color: _recording ? Colors.red : null,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '粘贴图片发送',
              onPressed: _pasteImage,
              icon: const Icon(Icons.image_outlined),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_tethering,
              size: 56, color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 12),
          const Text('从左侧选择一台设备开始聊天'),
          const SizedBox(height: 4),
          Text(
            '在局域网内打开本应用的设备会自动出现\n也可以点击"手动添加设备"输入 IP',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}