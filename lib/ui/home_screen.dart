import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chat_service.dart';
import '../core/models.dart';
import '../core/platform_keepalive.dart';
import 'chat_pane.dart';
import 'peer_list.dart';

/// 应用根界面:桌面端双栏(设备列表 + 会话窗格)、移动端主从导航。
class HomeScreen extends StatefulWidget {
  final ChatService service;

  const HomeScreen({super.key, required this.service});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ValueNotifier<bool> _keepAliveNotifier =
      ValueNotifier(PlatformKeepAlive.enabled);

  Future<void> _toggleKeepAlive(BuildContext context) async {
    if (PlatformKeepAlive.enabled) {
      await PlatformKeepAlive.stop();
    } else {
      final ok = await PlatformKeepAlive.start();
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('开启后台保活失败(需 Android 8+ 通知权限)')),
        );
      }
    }
    _keepAliveNotifier.value = PlatformKeepAlive.enabled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.lan, size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text(widget.service.self.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 10),
            _OnlineCount(service: widget.service),
            const SizedBox(width: 6),
            ValueListenableBuilder<int>(
              valueListenable: widget.service.totalUnread,
              builder: (context, total, _) {
                if (total <= 0) return const SizedBox.shrink();
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    total > 99 ? '99+' : '$total',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onError,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          if (PlatformKeepAlive.isSupported)
            ValueListenableBuilder<bool>(
              valueListenable: _keepAliveNotifier,
              builder: (context, on, _) => IconButton(
                tooltip: on ? '后台保活已开启,点击关闭' : '开启后台保活(常驻通知)',
                icon: Icon(
                  on ? Icons.notifications_active : Icons.notifications_none,
                  color: on ? Colors.green : null,
                ),
                onPressed: () => _toggleKeepAlive(context),
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.service.cryptoEnabled,
            builder: (context, enc, _) {
              return IconButton(
                tooltip: enc ? '配对加密已开启,点击关闭' : '开启配对加密',
                icon: Icon(
                  enc ? Icons.lock : Icons.lock_open,
                  color: enc ? Colors.green : null,
                ),
                onPressed: () => _togglePair(context),
              );
            },
          ),
          IconButton(
            tooltip: '搜索消息',
            icon: const Icon(Icons.search),
            onPressed: () => _showSearch(context),
          ),
          IconButton(
            tooltip: '修改本机名称',
            icon: const Icon(Icons.edit),
            onPressed: () => _rename(context),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 720) {
            return _buildDesktop(context);
          }
          return _buildMobile(context);
        },
      ),
      floatingActionButton: ValueListenableBuilder<String?>(
        valueListenable: widget.service.selectedPeerNotifier,
        builder: (context, selected, _) {
          // 群发入口:移动端用 FAB,桌面端在设备列表底部。
          final isNarrow = MediaQuery.of(context).size.width < 720;
          if (!isNarrow) return const SizedBox.shrink();
          return FloatingActionButton.small(
            tooltip: '群发消息',
            onPressed: () => _showBroadcastDialog(context),
            child: const Icon(Icons.campaign_outlined),
          );
        },
      ),
    );
  }

  Future<void> _togglePair(BuildContext context) async {
    if (widget.service.isEncrypted) {
      widget.service.disablePairing();
      return;
    }
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开启配对加密'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('输入两设备共享的口令(6 位以上)。对方设备需使用相同口令。'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: '共享口令',
                hintText: '例如 123456',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('开启'),
          ),
        ],
      ),
    );
    if (code != null && code.isNotEmpty && code.length >= 6) {
      await widget.service.enablePairing(code);
    }
  }

  Widget _buildDesktop(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 264,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    const Icon(Icons.people_outline, size: 16),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text('设备',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      tooltip: '手动添加设备',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add, size: 18),
                      onPressed: () => showAddPeerDialog(widget.service),
                    ),
                  ],
                ),
              ),
              const Divider(height: 8),
              GroupList(service: widget.service),
              Expanded(child: PeerList(service: widget.service)),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.campaign_outlined, size: 20),
                title: const Text('群发消息'),
                onTap: () => _showBroadcastDialog(context),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.group_add_outlined, size: 20),
                title: const Text('创建群组'),
                onTap: () => _showCreateGroupDialog(context),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: ChatPane(service: widget.service)),
      ],
    );
  }

  Future<void> _showBroadcastDialog(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('群发消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '发送给所有在线设备',
            hintText: '例如:今晚 20:00 例会',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('群发'),
          ),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) {
      await widget.service.broadcast(text);
    }
  }

  Future<void> _showCreateGroupDialog(BuildContext context) async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('创建群组'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            labelText: '群名称',
            hintText: '例如:家庭群',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    // 选择成员:当前在线设备(除自己外)。
    final peers = widget.service.peersNotifier.value
        .where((p) => p.online)
        .toList();
    if (peers.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有在线设备可邀请')),
        );
      }
      return;
    }
    final selected = <String>{};
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInnerState) => AlertDialog(
          title: const Text('选择成员'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: peers.map((p) {
                return CheckboxListTile(
                  title: Text(p.name),
                  subtitle: Text(p.platform, style: const TextStyle(fontSize: 12)),
                  value: selected.contains(p.id),
                  onChanged: (v) {
                    setInnerState(() {
                      if (v == true) {
                        selected.add(p.id);
                      } else {
                        selected.remove(p.id);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && selected.isNotEmpty) {
      await widget.service.createGroup(name, selected.toList());
    }
  }

  Widget _buildMobile(BuildContext context) {
    // 选中态驱动:私聊对端 / 群 / 群发任一选中即进入会话视图。
    return ValueListenableBuilder<String?>(
      valueListenable: widget.service.selectedPeerNotifier,
      builder: (context, selected, _) {
        final selectedKind = selected == null
            ? 'none'
            : (selected.startsWith('group-')
                ? 'group'
                : (selected == 'broadcast' ? 'broadcast' : 'peer'));
        final inChat = selected != null &&
            (selectedKind == 'peer'
                ? widget.service.peer(selected) != null
                : true);

        if (inChat) {
          return Stack(
            children: [
              ChatPane(service: widget.service),
              Positioned(
                top: 8,
                left: 8,
                child: Material(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.9),
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: IconButton(
                    tooltip: '返回设备列表',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => widget.service.select(null),
                  ),
                ),
              ),
            ],
          );
        }
        return Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                PeerList(service: widget.service),
                if (widget.service.peersNotifier.value.isEmpty)
                  const Center(
                    child: Text('还没有发现设备\n打开另一台设备上的 LanChat',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)),
                  ),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton.small(
            tooltip: '手动添加设备',
            onPressed: () => showAddPeerDialog(widget.service),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: widget.service.self.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改本机名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(labelText: '设备名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await widget.service.renameSelf(name);
      setState(() {});
    }
  }

  Future<void> _showSearch(BuildContext context) async {
    final controller = TextEditingController();
    final results = <SearchResult>[];
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: const Text('搜索消息'),
          content: SizedBox(
            width: 420,
            height: 320,
            child: Column(
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '输入关键词…',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onSubmitted: (_) => _doSearch(controller.text, setInner, results),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _SearchResults(
                    service: widget.service,
                    controller: controller,
                    setInner: setInner,
                    results: results,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doSearch(String keyword,
      StateSetter setInner, List<SearchResult> results) async {
    final found = await widget.service.search(keyword);
    results
      ..clear()
      ..addAll(found);
    setInner(() {});
  }
}

/// 搜索结果列表(点击跳转到对应会话)。
class _SearchResults extends StatelessWidget {
  final ChatService service;
  final TextEditingController controller;
  final StateSetter setInner;
  final List<SearchResult> results;

  const _SearchResults({
    required this.service,
    required this.controller,
    required this.setInner,
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const Center(
        child: Text('没有匹配结果', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: results.length,
      itemBuilder: (context, index) {
        final r = results[index];
        final sessionLabel = r.isGroup
            ? (service.selectedGroup?.name ?? '群聊')
            : (service.peer(r.sessionId)?.name ?? '会话');
        return ListTile(
          dense: true,
          leading: Icon(r.isGroup ? Icons.group_outlined : Icons.person_outline,
              size: 18),
          title: Text(r.text,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('$sessionLabel · ${_fmtTime(r.ts)}',
              style: const TextStyle(fontSize: 12)),
          onTap: () {
            service.select(r.sessionId);
            Navigator.pop(context);
          },
        );
      },
    );
  }

  static String _fmtTime(int ts) {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

class _OnlineCount extends StatelessWidget {
  final ChatService service;

  const _OnlineCount({required this.service});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Peer>>(
      valueListenable: service.peersNotifier,
      builder: (context, peers, _) {
        final online = peers.where((p) => p.online).length;
        return Chip(
          label: Text('$online 在线', style: const TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
      },
    );
  }
}