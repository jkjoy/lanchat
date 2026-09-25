import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/chat_service.dart';
import '../core/group.dart';

/// 全局导航 key，供桌面端回调和内部对话框使用。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 通用"手动添加设备"对话框（桌面端与移动端共用）。
Future<void> showAddPeerDialog(ChatService service) async {
  final controller = TextEditingController();
  final navigator = navigatorKey.currentState;
  if (navigator == null) return;
  final host = await showDialog<String>(
    context: navigator.context,
    builder: (context) => AlertDialog(
      title: const Text('手动添加设备'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: '设备 IP 地址',
          hintText: '例如 192.168.1.100',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('添加'),
        ),
      ],
    ),
  );
  if (host != null && host.isNotEmpty) {
    await service.addManualPeer(host);
  }
}

/// 会话列表页（移动端主界面/桌面端左侧栏公用）。
class PeerList extends StatelessWidget {
  final ChatService service;

  const PeerList({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Peer>>(
      valueListenable: service.peersNotifier,
      builder: (context, peers, _) {
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: peers.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _BroadcastTile(
                service: service,
                selected: service.selectedPeerNotifier.value == 'broadcast',
              );
            }
            final peer = peers[index - 1];
            return ValueListenableBuilder<Map<String, int>>(
              valueListenable: service.unreadMap,
              builder: (context, unread, _) => _PeerTile(
                service: service,
                peer: peer,
                selected: service.selectedPeerNotifier.value == peer.id,
                unread: unread[peer.id] ?? 0,
              ),
            );
          },
        );
      },
    );
  }
}

/// 群发会话入口（选择后进入群发消息视图）。
/// 群列表(在设备列表上方显示已加入的群,点击进入群会话)。
class GroupList extends StatelessWidget {
  final ChatService service;

  const GroupList({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Group>>(
      valueListenable: service.groupsNotifier,
      builder: (context, groups, _) {
        if (groups.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('我的群组',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
            for (final g in groups)
              ValueListenableBuilder<Map<String, int>>(
                valueListenable: service.unreadMap,
                builder: (context, unread, _) => ListTile(
                  dense: true,
                  leading: Icon(Icons.group_outlined, size: 20),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(g.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      if ((unread[g.id] ?? 0) > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${unread[g.id]}',
                            style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onError,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Text('${g.memberIds.length} 人',
                      style: const TextStyle(fontSize: 12)),
                  selected: service.selectedPeerNotifier.value == g.id,
                  onTap: () => service.select(g.id),
                ),
              ),
            const Divider(height: 1),
          ],
        );
      },
    );
  }
}

class _BroadcastTile extends StatelessWidget {
  final ChatService service;
  final bool selected;

  const _BroadcastTile({required this.service, required this.selected});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
      leading: const Icon(Icons.campaign_outlined),
      title: const Text('群发消息'),
      subtitle: const Text('发送给所有在线设备', style: TextStyle(fontSize: 12)),
      onTap: () => service.select('broadcast'),
    );
  }
}

class _PeerTile extends StatelessWidget {
  final ChatService service;
  final Peer peer;
  final bool selected;
  final int unread;

  const _PeerTile({
    required this.service,
    required this.peer,
    required this.selected,
    this.unread = 0,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
      leading: _PeerAvatar(peer: peer),
      title: Row(
        children: [
          Expanded(
            child: Text(peer.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onError,
                    fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
      subtitle: Text(
        peer.online ? peer.platformLabel : '离线',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: peer.online ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
      onTap: () => service.select(peer.id),
    );
  }
}

class _PeerAvatar extends StatelessWidget {
  final Peer peer;

  const _PeerAvatar({required this.peer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = peer.online ? scheme.primary : scheme.surfaceContainerHighest;
    final letter = peer.name.isEmpty ? '?' : peer.name[0].toUpperCase();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: color.withValues(alpha: 0.25),
          child: Text(letter, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: peer.online ? Colors.green : scheme.outlineVariant,
              border: Border.all(color: scheme.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

extension on Peer {
  String get platformLabel {
    switch (platform) {
      case 'windows':
        return 'Windows 在线';
      case 'android':
        return 'Android 在线';
      case 'macos':
        return 'macOS 在线';
      case 'linux':
        return 'Linux 在线';
      default:
        return '在线';
    }
  }
}