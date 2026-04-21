import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api/chat.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const FerryApp());
}

class FerryApp extends StatelessWidget {
  const FerryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ferry',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90D9)),
        useMaterial3: true,
      ),
      home: const SetupScreen(),
    );
  }
}

// ── Setup screen ──────────────────────────────────────────────────────────────

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String _error = '';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a username');
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dataDir = '${dir.path}/ferry_chat';
      chatInit(userName: name, dataDir: dataDir);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_rounded, size: 72, color: Color(0xFF4A90D9)),
              const SizedBox(height: 16),
              const Text('Ferry', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Encrypted peer-to-peer chat', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 40),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _start(),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_error, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading ? null : _start,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Start'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chat list screen ──────────────────────────────────────────────────────────

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<ChatInfo> _chats = [];
  List<String> _peers = [];
  ChatStatusInfo? _status;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _chats = chatListChats();
      _peers = chatListPeers();
      _status = chatGetStatus();
    });
  }

  void _poll() {
    try {
      final newSenders = chatPoll();
      if (newSenders.isNotEmpty || (_status?.pendingCount ?? 0) > 0) {
        _refresh();
      } else {
        // Still refresh peers and pending counts periodically
        setState(() {
          _peers = chatListPeers();
          _status = chatGetStatus();
          _chats = chatListChats();
        });
      }
    } catch (_) {}
  }

  Future<void> _showIntroDialog() async {
    String? intro;
    String? error;
    try {
      intro = chatGetIntro();
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    final status = chatGetStatus();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your Intro Bundle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show IP:port prominently so friend can use manual entry
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F4FD),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi, size: 16, color: Color(0xFF4A90D9)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${status.localIp}:${status.tcpPort}',
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 14),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Copy address',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(
                          text: '${status.localIp}:${status.tcpPort}'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Address copied')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text('Intro bundle (share with friend):',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            if (error != null)
              Text(error, style: const TextStyle(color: Colors.red))
            else
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(intro ?? '',
                    style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
        actions: [
          if (intro != null)
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy Bundle'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: intro!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Bundle copied to clipboard')),
                );
              },
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddFriendDialog() async {
    final nameCtrl = TextEditingController();
    final bundleCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    String errorMsg = '';
    bool showAddrField = false;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Add Friend'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: "Friend's name",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bundleCtrl,
                  decoration: const InputDecoration(
                    labelText: "Paste their intro bundle",
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 8),
                // Manual IP fallback toggle
                GestureDetector(
                  onTap: () => setS(() => showAddrField = !showAddrField),
                  child: Row(
                    children: [
                      Icon(
                        showAddrField
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        "mDNS not working? Enter IP:port manually",
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                if (showAddrField) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: addrCtrl,
                    decoration: const InputDecoration(
                      labelText: "Friend's IP:port (e.g. 192.168.1.5:54321)",
                      border: OutlineInputBorder(),
                      hintText: "192.168.1.x:PORT",
                    ),
                    keyboardType: TextInputType.url,
                  ),
                ],
                if (errorMsg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(errorMsg,
                      style: const TextStyle(color: Colors.red, fontSize: 13)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final bundle = bundleCtrl.text.trim();
                if (name.isEmpty || bundle.isEmpty) {
                  setS(() => errorMsg = 'Name and bundle are required');
                  return;
                }
                try {
                  // Register manual address first if provided
                  final addr = addrCtrl.text.trim();
                  if (addr.isNotEmpty) {
                    chatAddPeerAddr(name: name, addr: addr);
                  }
                  chatAddFriend(remoteUser: name, bundle: bundle);
                  Navigator.pop(ctx);
                  _refresh();
                  Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) => ChatScreen(remoteUser: name)))
                      .then((_) => _refresh());
                } catch (e) {
                  setS(() => errorMsg = e.toString());
                }
              },
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    bundleCtrl.dispose();
    addrCtrl.dispose();
  }

  Future<void> _showStatusDialog() async {
    final s = chatGetStatus();
    final peers = chatListPeersWithAddrs();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusRow('User', s.userName),
            _statusRow('Local IP', s.localIp),
            _statusRow('TCP port', s.tcpPort.toString()),
            _statusRow('Chats', s.chatCount.toString()),
            if (s.pendingCount > 0)
              _statusRow('Pending', '${s.pendingCount} unsent', color: Colors.orange),
            _statusRow('Active', s.activeChat.isEmpty ? '—' : s.activeChat),
            if (peers.isNotEmpty) ...[
              const Divider(),
              const Text('Discovered peers:',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              ...peers.map((p) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('  ${p.name}  ${p.addr}',
                        style: const TextStyle(fontSize: 12)),
                  )),
            ],
            const Divider(),
            const Text('Address (hex):',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            SelectableText(
              s.addressHex,
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _statusRow(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text('$label: ',
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                  color: color)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final pendingCount = _status?.pendingCount ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ferry'),
            if (_status != null)
              Text(_status!.userName,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
        actions: [
          if (pendingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                label: Text('$pendingCount pending',
                    style: const TextStyle(fontSize: 11)),
                backgroundColor: Colors.orange[100],
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Show my intro',
            onPressed: _showIntroDialog,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Status',
            onPressed: _showStatusDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // Discovered peers banner
          if (_peers.isNotEmpty)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFFE8F4FD),
              child: Row(
                children: [
                  const Icon(Icons.wifi, size: 16, color: Color(0xFF4A90D9)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Nearby (mDNS): ${_peers.join(', ')}',
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF2C6FAC)),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _chats.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 64, color: Colors.grey[300]),
                        const SizedBox(height: 16),
                        Text('No chats yet',
                            style: TextStyle(color: Colors.grey[500])),
                        const SizedBox(height: 8),
                        Text('Tap + to add a friend',
                            style: TextStyle(
                                color: Colors.grey[400], fontSize: 13)),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _chats.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final chat = _chats[i];
                      return ListTile(
                        leading: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              backgroundColor: _colorFor(chat.remoteUser),
                              child: Text(
                                chat.remoteUser[0].toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            if (chat.hasPending)
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: const BoxDecoration(
                                    color: Colors.orange,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        title: Text(chat.remoteUser),
                        subtitle: chat.hasPending
                            ? const Text('Pending — waiting for peer…',
                                style: TextStyle(
                                    color: Colors.orange, fontSize: 12))
                            : Text(
                                '${chat.messageCount} message${chat.messageCount == 1 ? '' : 's'}'),
                        trailing: chat.isActive
                            ? const Icon(Icons.circle,
                                size: 10, color: Color(0xFF4A90D9))
                            : null,
                        onTap: () {
                          chatSwitch(remoteUser: chat.remoteUser);
                          Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) =>
                                      ChatScreen(remoteUser: chat.remoteUser)))
                              .then((_) => _refresh());
                        },
                        onLongPress: () => _confirmDelete(chat.remoteUser),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddFriendDialog,
        child: const Icon(Icons.person_add),
      ),
    );
  }

  Future<void> _confirmDelete(String remoteUser) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
            'Delete your conversation with $remoteUser? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        chatDelete(remoteUser: remoteUser);
        _refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.toString())));
        }
      }
    }
  }

  Color _colorFor(String name) {
    final colors = [
      const Color(0xFF4A90D9),
      const Color(0xFF7B68EE),
      const Color(0xFF20B2AA),
      const Color(0xFFFF6B6B),
      const Color(0xFF98D8C8),
      const Color(0xFFFFB347),
    ];
    return colors[name.codeUnitAt(0) % colors.length];
  }
}

// ── Chat screen ───────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  final String remoteUser;
  const ChatScreen({super.key, required this.remoteUser});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<ChatMessage> _messages = [];
  Timer? _pollTimer;
  bool _sending = false;
  String _error = '';
  bool _hasPending = false;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _loadMessages() {
    final chats = chatListChats();
    final info = chats.where((c) => c.remoteUser == widget.remoteUser).firstOrNull;
    setState(() {
      _messages = chatGetMessages();
      _hasPending = info?.hasPending ?? false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _poll() {
    try {
      chatPoll();
      final chats = chatListChats();
      final info =
          chats.where((c) => c.remoteUser == widget.remoteUser).firstOrNull;
      final wasPending = _hasPending;
      setState(() {
        _messages = chatGetMessages();
        _hasPending = info?.hasPending ?? false;
      });
      if (wasPending && !_hasPending) {
        // Pending cleared — scroll to show delivery confirmed
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } catch (_) {}
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _sending = true;
      _error = '';
    });
    try {
      chatSend(content: text);
      _inputCtrl.clear();
      _loadMessages();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _sending = false);
    }
  }

  Future<void> _showSetAddrDialog() async {
    final addrCtrl = TextEditingController();
    final status = chatGetStatus();
    String errorMsg = '';

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Set address for ${widget.remoteUser}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'mDNS discovery failed. Ask ${widget.remoteUser} for their IP:port from the "Show intro" screen.',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                'Your address: ${status.localIp}:${status.tcpPort}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: addrCtrl,
                decoration: InputDecoration(
                  labelText: "${widget.remoteUser}'s IP:port",
                  border: const OutlineInputBorder(),
                  hintText: '192.168.1.x:PORT',
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              if (errorMsg.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(errorMsg,
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final addr = addrCtrl.text.trim();
                if (addr.isEmpty) {
                  setS(() => errorMsg = 'Enter an address');
                  return;
                }
                try {
                  chatAddPeerAddr(name: widget.remoteUser, addr: addr);
                  Navigator.pop(ctx);
                  setState(() => _error = '');
                } catch (e) {
                  setS(() => errorMsg = e.toString());
                }
              },
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    addrCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: _colorFor(widget.remoteUser),
              child: Text(
                widget.remoteUser[0].toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),
            ),
            const SizedBox(width: 10),
            Text(widget.remoteUser),
            if (_hasPending) ...[
              const SizedBox(width: 8),
              const Icon(Icons.schedule, size: 16, color: Colors.orange),
            ],
          ],
        ),
        actions: [
          if (_hasPending)
            IconButton(
              icon: const Icon(Icons.network_wifi, color: Colors.orange),
              tooltip: 'Set peer address manually',
              onPressed: _showSetAddrDialog,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_hasPending)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.orange[50],
              child: Row(
                children: [
                  const Icon(Icons.schedule, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Waiting to reach peer — mDNS discovery in progress or enter address manually.',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
                  TextButton(
                    onPressed: _showSetAddrDialog,
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 0)),
                    child: const Text('Set addr',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text('No messages yet',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (ctx, i) => _buildMessage(_messages[i]),
                  ),
          ),
          if (_error.isNotEmpty)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.red[50],
              child: Text(_error,
                  style:
                      const TextStyle(color: Colors.red, fontSize: 13)),
            ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessage(ChatMessage msg) {
    final isMe = msg.fromSelf;
    final isPending = msg.content.endsWith('(pending…)');
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMe
              ? (isPending
                  ? Colors.orange[200]
                  : const Color(0xFF4A90D9))
              : Colors.grey[200],
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
        ),
        child: Text(
          msg.content,
          style: TextStyle(
              color: isMe ? Colors.white : Colors.black87),
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                decoration: InputDecoration(
                  hintText: 'Message ${widget.remoteUser}…',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  isDense: true,
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                minLines: 1,
                maxLines: 4,
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
              ),
              child: _sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  Color _colorFor(String name) {
    final colors = [
      const Color(0xFF4A90D9),
      const Color(0xFF7B68EE),
      const Color(0xFF20B2AA),
      const Color(0xFFFF6B6B),
      const Color(0xFF98D8C8),
      const Color(0xFFFFB347),
    ];
    return colors[name.codeUnitAt(0) % colors.length];
  }
}
