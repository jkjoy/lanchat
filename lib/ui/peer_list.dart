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
                builder: (context, unread, _) {
                  final scheme = Theme.of(context).colorScheme;
                  final isSelected =
                      service.selectedPeerNotifier.value == g.id;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    child: Material(
                      color: isSelected
                          ? scheme.primary.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => service.select(g.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF7C4DFF),
                                      Color(0xFF536DFE)
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: const Icon(Icons.group_rounded,
                                    color: Colors.white, size: 19),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(g.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14.5)),
                                    const SizedBox(height: 1),
                                    Text('${g.memberIds.length} 人',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: scheme
                                                .onSurfaceVariant)),
                                  ],
                                ),
                              ),
                              if ((unread[g.id] ?? 0) > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: scheme.error,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${unread[g.id]}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: scheme.onError,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => service.select('broadcast'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFF9F43), Color(0xFFEE5A24)],
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.campaign_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('群发消息',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(
                        '发送给所有在线设备',
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => service.select(peer.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: [
                _PeerAvatar(peer: peer),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(peer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(
                        peer.online ? peer.platformLabel : '离线',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: peer.online
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
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
          ),
        ),
      ),
    );
  }
}

class _PeerAvatar extends StatelessWidget {
  final Peer peer;

  const _PeerAvatar({required this.peer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 平台专属图标与配色。
    final (IconData icon, List<Color> colors) = switch (peer.platform) {
      'windows' => (
          Icons.laptop_windows_rounded,
          [const Color(0xFF00A4EF), const Color(0xFF0078D4)]
        ),
      'android' => (
          Icons.phone_android_rounded,
          [const Color(0xFF3DDC84), const Color(0xFF2BB673)]
        ),
      'macos' => (
          Icons.laptop_mac_rounded,
          [const Color(0xFFA2AAAD), const Color(0xFF6E6E73)]
        ),
      'linux' => (
          Icons.terminal_rounded,
          [const Color(0xFFf9bc4e), const Color(0xFFe95420)]
        ),
      _ => (
          Icons.devices_rounded,
          [scheme.primary, scheme.tertiary]
        ),
    };

    final dimmed = !peer.online;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dimmed
                  ? colors
                      .map((c) => c.withValues(alpha: 0.35))
                      .toList()
                  : colors,
            ),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: Colors.white, size: 21),
        ),
        // 在线状态点。
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 13,
            height: 13,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: peer.online ? const Color(0xFF34C759) : scheme.outlineVariant,
              border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor, width: 2.5),
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