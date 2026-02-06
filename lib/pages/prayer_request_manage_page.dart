import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/post_service.dart';

/// Must match the form page collection name
const String _kPrayerRequestsCol = 'prayerRequests';

class PrayerRequestManagePage extends StatefulWidget {
  const PrayerRequestManagePage({super.key, this.initialRequestId});

  final String? initialRequestId;

  @override
  State<PrayerRequestManagePage> createState() => _PrayerRequestManagePageState();
}

class _PrayerRequestManagePageState extends State<PrayerRequestManagePage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _postService = PostService();

  bool _loadingRole = true;
  bool _canModerate = false; // pastor || admin
  String? _uid;

  // Default to "all" so nothing gets hidden by status
  String _statusFilter = 'all'; // new | acknowledged | archived | all
  String _search = '';
  final _searchCtrl = TextEditingController();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSub;
  String? _focusRequestId;
  bool _autoOpened = false;

  String? _prayerTowerMinistryId;
  String? _prayerTowerMinistryName;
  bool _resolvingPrayerTower = false;

  @override
  void initState() {
    super.initState();

    // Make sure the ID token is fresh so Firestore Rules see current claims.
    FirebaseAuth.instance.currentUser?.getIdToken(true);

    _wireRole();
    _searchCtrl.addListener(() {
      setState(() => _search = _searchCtrl.text.trim().toLowerCase());
    });

    final rawFocus = widget.initialRequestId?.trim() ?? '';
    _focusRequestId = rawFocus.isNotEmpty ? rawFocus : null;
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // Mirrors RoleGate: users -> claims -> member fallback
  Future<void> _wireRole() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _loadingRole = false;
        _canModerate = false;
      });
      return;
    }
    _uid = user.uid;

    _userSub = _db.collection('users').doc(user.uid).snapshots().listen((snap) async {
      final data = snap.data() ?? {};
      final roles = <String>{};

      // users.roles, role, booleans
      if (data['roles'] is List) {
        for (final v in List.from(data['roles'])) {
          if (v is String && v.trim().isNotEmpty) roles.add(v.toLowerCase().trim());
        }
      }
      if (data['role'] is String) roles.add((data['role'] as String).toLowerCase().trim());
      if (data['isPastor'] == true) roles.add('pastor');
      if (data['isAdmin'] == true) roles.add('admin');

      // custom claims
      try {
        final token = await user.getIdTokenResult(true);
        final c = token.claims ?? {};
        if (c['pastor'] == true || c['isPastor'] == true) roles.add('pastor');
        if (c['admin'] == true || c['isAdmin'] == true) roles.add('admin');
      } catch (_) {}

      // member fallback
      try {
        final memberId = (data['memberId'] ?? '').toString();
        if (memberId.isNotEmpty) {
          final mem = await _db.collection('members').doc(memberId).get();
          if (mem.exists) {
            final m = mem.data() ?? {};
            final mroles = (m['roles'] as List<dynamic>? ?? const [])
                .map((e) => e.toString().toLowerCase())
                .toSet();
            final leads = (m['leadershipMinistries'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList();
            if (mroles.contains('admin')) roles.add('admin');
            if (mroles.contains('pastor') || (m['isPastor'] == true)) roles.add('pastor');
            if (mroles.contains('leader') || leads.isNotEmpty) roles.add('leader');
          }
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _canModerate = roles.contains('pastor') || roles.contains('admin');
        _loadingRole = false;
      });
    });
  }

  /// Stream WITHOUT server-side orderBy (to avoid empty results when field names/types vary).
  /// We sort by requestedAt on the client below.
  Stream<QuerySnapshot<Map<String, dynamic>>> _baseStream() {
    return _db.collection(_kPrayerRequestsCol).limit(500).snapshots();
  }

  Future<void> _markPrayed(DocumentSnapshot d) async {
    if (!_canModerate || _uid == null) return;
    try {
      await d.reference.update({
        'status': 'acknowledged',
        'acknowledgedAt': FieldValue.serverTimestamp(),
        'acknowledgedByUid': _uid,
        // Back-compat fields (older clients)
        'prayedAt': FieldValue.serverTimestamp(),
        'prayedByUid': _uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Acknowledged')),
        );
      }
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _archive(DocumentSnapshot d) async {
    if (!_canModerate) return;
    try {
      await d.reference.update({
        'status': 'archived',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Archived')),
        );
      }
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _restore(DocumentSnapshot d) async {
    if (!_canModerate) return;
    try {
      await d.reference.update({
        'status': 'new',
        'acknowledgedAt': null,
        'acknowledgedByUid': null,
        'prayedAt': null,
        'prayedByUid': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Restored to new')),
        );
      }
    } catch (e) {
      _toastError(e);
    }
  }

  Future<void> _addNote(DocumentSnapshot d) async {
    final ctrl = TextEditingController(text: (d['notes'] ?? '').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add / update note'),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await d.reference.update({
          'notes': ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Notes saved')),
          );
        }
      } catch (e) {
        _toastError(e);
      }
    }
  }

  void _toastError(Object e) {
    final msg = (e is FirebaseException) ? (e.message ?? e.code) : e.toString();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ $msg')));
  }

  String _statusCategory(String raw) {
    final s = raw.trim().toLowerCase();
    if (s == 'acknowledged' || s == 'prayed') return 'acknowledged';
    if (s == 'archived') return 'archived';
    return 'new';
  }

  String _displayStatus(String raw) {
    final cat = _statusCategory(raw);
    switch (cat) {
      case 'acknowledged':
        return 'ACKNOWLEDGED';
      case 'archived':
        return 'ARCHIVED';
      default:
        return 'NEW';
    }
  }

  Color _statusColor(String raw) {
    final cat = _statusCategory(raw);
    switch (cat) {
      case 'acknowledged':
        return Colors.green.shade100;
      case 'archived':
        return Colors.grey.shade300;
      default:
        return Colors.blue.shade100;
    }
  }

  Future<bool> _resolvePrayerTowerMinistry() async {
    if (_prayerTowerMinistryId != null) return true;
    if (_resolvingPrayerTower) return false;
    _resolvingPrayerTower = true;
    try {
      const candidates = [
        'Prayer Tower',
        'Prayer Tower Ministry',
      ];
      for (final name in candidates) {
        final q = await _db
            .collection('ministries')
            .where('name', isEqualTo: name)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          _prayerTowerMinistryId = q.docs.first.id;
          _prayerTowerMinistryName = (q.docs.first.data()['name'] ?? name).toString();
          return true;
        }
      }

      // Fallback: find any ministry containing "prayer tower"
      final q = await _db.collection('ministries').limit(200).get();
      for (final d in q.docs) {
        final name = (d.data()['name'] ?? '').toString();
        if (name.toLowerCase().contains('prayer tower')) {
          _prayerTowerMinistryId = d.id;
          _prayerTowerMinistryName = name;
          return true;
        }
      }
      return false;
    } finally {
      _resolvingPrayerTower = false;
    }
  }

  Future<String?> _resolveAuthorName() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    try {
      final uSnap = await _db.collection('users').doc(uid).get();
      final u = uSnap.data() ?? {};
      final display = (u['displayName'] ?? '').toString().trim();
      if (display.isNotEmpty) return display;
      final memberId = (u['memberId'] ?? '').toString().trim();
      if (memberId.isNotEmpty) {
        final mSnap = await _db.collection('members').doc(memberId).get();
        final m = mSnap.data() ?? {};
        final full = (m['fullName'] ?? '').toString().trim();
        if (full.isNotEmpty) return full;
        final first = (m['firstName'] ?? '').toString().trim();
        final last = (m['lastName'] ?? '').toString().trim();
        final composed = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
        if (composed.isNotEmpty) return composed;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _forwardToPrayerTower(DocumentSnapshot<Map<String, dynamic>> d) async {
    if (!_canModerate || _uid == null) return;
    final data = d.data() ?? {};
    final alreadyForwarded =
        (data['forwardedToPrayerTowerAt'] is Timestamp) ||
        (data['forwardedToPrayerTower'] == true);
    if (alreadyForwarded) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forward to Prayer Tower'),
        content: const Text(
          'This will share the request with the Prayer Tower ministry. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forward')),
        ],
      ),
    );
    if (ok != true) return;

    final resolved = await _resolvePrayerTowerMinistry();
    if (!resolved || _prayerTowerMinistryId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Prayer Tower ministry not found.')),
        );
      }
      return;
    }

    try {
      final isAnon = data['isAnonymous'] == true;
      final name = (data['name'] ?? '').toString().trim();
      final email = (data['email'] ?? '').toString().trim();
      final message = (data['message'] ?? '').toString().trim();
      final requester = isAnon
          ? 'Anonymous'
          : [name, email].where((s) => s.isNotEmpty).join(' • ').trim().isNotEmpty
              ? [name, email].where((s) => s.isNotEmpty).join(' • ')
              : 'Member';

      final authorName = await _resolveAuthorName();

      final text = [
        'Prayer Request (Forwarded)',
        'From: $requester',
        if (message.isNotEmpty) '',
        message.isNotEmpty ? message : '(no message)',
      ].join('\n');

      await _postService.createPost(
        ministryId: _prayerTowerMinistryId!,
        authorId: _uid!,
        authorName: authorName,
        text: text,
      );

      await d.reference.update({
        'forwardedToPrayerTower': true,
        'forwardedToPrayerTowerAt': FieldValue.serverTimestamp(),
        'forwardedToPrayerTowerByUid': _uid,
        'forwardedToPrayerTowerMinistryId': _prayerTowerMinistryId,
        'forwardedToPrayerTowerMinistryName': _prayerTowerMinistryName,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Forwarded to Prayer Tower')),
        );
      }
    } catch (e) {
      _toastError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_canModerate) {
      return Scaffold(
        appBar: AppBar(title: const Text('Prayer Requests')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Text(
              'Access denied.\nOnly pastors and admins can manage prayer requests.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Prayer Requests'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _statusFilter,
            onSelected: (v) => setState(() => _statusFilter = v),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'new', child: Text('New')),
              PopupMenuItem(value: 'acknowledged', child: Text('Acknowledged')),
              PopupMenuItem(value: 'archived', child: Text('Archived')),
              PopupMenuItem(value: 'all', child: Text('All')),
            ],
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter status',
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by name, email, or message…',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => _searchCtrl.clear(),
                )
                    : null,
              ),
            ),
          ),
          const Divider(height: 0),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _baseStream(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        'Could not load prayer requests:\n${snap.error}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                // All docs from server (no order). Sort by requestedAt desc locally.
                final docs = snap.data!.docs;
                final sorted = [...docs]..sort((a, b) {
                  final ta = a.data()['requestedAt'];
                  final tb = b.data()['requestedAt'];
                  final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                  final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                  return db.compareTo(da); // desc
                });

                // Build counters (treat missing status as 'new')
                int cntAll = sorted.length;
                int cntNew = 0, cntAck = 0, cntArchived = 0;
                for (final d in sorted) {
                  final s = _statusCategory((d.data()['status'] ?? 'new').toString());
                  if (s == 'acknowledged') {
                    cntAck++;
                  } else if (s == 'archived') {
                    cntArchived++;
                  } else {
                    cntNew++;
                  }
                }

                // Status filter in memory
                Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> list = sorted;
                if (_statusFilter != 'all') {
                  list = list.where((d) {
                    final s = _statusCategory((d.data()['status'] ?? 'new').toString());
                    return s == _statusFilter;
                  });
                }

                // Local search filter
                final filtered = list.where((d) {
                  if (_search.isEmpty) return true;
                  final data = d.data();
                  final hay = [
                    (data['name'] ?? '').toString(),
                    (data['email'] ?? '').toString(),
                    (data['message'] ?? '').toString(),
                  ].join(' ').toLowerCase();
                  return hay.contains(_search);
                }).toList();

                final focused = _focusRequestId != null && _focusRequestId!.isNotEmpty;
                final visible = focused
                    ? filtered.where((d) => d.id == _focusRequestId).toList()
                    : filtered;

                return Column(
                  children: [
                    if (focused)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Row(
                          children: [
                            const Icon(Icons.filter_alt_outlined, size: 18),
                            const SizedBox(width: 6),
                            const Expanded(child: Text('Showing request from notification')),
                            TextButton(
                              onPressed: () => setState(() {
                                _focusRequestId = null;
                                _autoOpened = false;
                              }),
                              child: const Text('Show all'),
                            ),
                          ],
                        ),
                      ),

                    // Counter bar
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          _countChip('All', cntAll, selected: _statusFilter == 'all', onTap: () {
                            setState(() => _statusFilter = 'all');
                          }),
                          _countChip('New', cntNew, selected: _statusFilter == 'new', onTap: () {
                            setState(() => _statusFilter = 'new');
                          }),
                          _countChip('Acknowledged', cntAck, selected: _statusFilter == 'acknowledged', onTap: () {
                            setState(() => _statusFilter = 'acknowledged');
                          }),
                          _countChip('Archived', cntArchived, selected: _statusFilter == 'archived', onTap: () {
                            setState(() => _statusFilter = 'archived');
                          }),
                        ],
                      ),
                    ),
                    const Divider(height: 0),

                    // List
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(child: Text('No requests.'))
                          : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: visible.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final doc = visible[i];
                          final data = doc.data();
                          final isAnon = data['isAnonymous'] == true;

                          final name = (data['name'] ?? '').toString();
                          final email = (data['email'] ?? '').toString();
                          final msg = (data['message'] ?? '').toString();

                          final rawStatus = (data['status'] ?? 'new').toString();
                          final status = _statusCategory(rawStatus);
                          final prayedByUid = (data['acknowledgedByUid'] ?? data['prayedByUid'] ?? '').toString();
                          final forwarded =
                              (data['forwardedToPrayerTowerAt'] is Timestamp) ||
                              (data['forwardedToPrayerTower'] == true);
                          final requestedAt = data['requestedAt'];
                          final dt = requestedAt is Timestamp ? requestedAt.toDate() : null;

                          if (_focusRequestId != null && !_autoOpened && doc.id == _focusRequestId) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted) return;
                              setState(() => _autoOpened = true);
                            });
                          }

                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: [
                                      Chip(
                                        label: Text(_displayStatus(rawStatus)),
                                        backgroundColor: _statusColor(rawStatus),
                                      ),
                                      if (isAnon)
                                        const Chip(
                                          label: Text('Anonymous'),
                                          avatar: Icon(Icons.visibility_off, size: 16),
                                        ),
                                      if (!isAnon && name.isNotEmpty) Chip(label: Text(name)),
                                      if (!isAnon && email.isNotEmpty)
                                        Chip(
                                          label: Text(email),
                                          avatar: const Icon(Icons.email, size: 16),
                                        ),
                                      if (prayedByUid.isNotEmpty)
                                        Chip(
                                          label: Text('Acknowledged by: $prayedByUid'),
                                          avatar: const Icon(Icons.volunteer_activism, size: 16),
                                        ),
                                      if (dt != null)
                                        Chip(
                                          label: Text('At: ${dt.toLocal()}'),
                                          avatar: const Icon(Icons.access_time, size: 16),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    msg.isEmpty ? '(no message)' : msg,
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                  if ((data['notes'] ?? '').toString().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      'Notes: ${(data['notes']).toString()}',
                                      style: TextStyle(color: Colors.grey.shade700),
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton.icon(
                                        onPressed: () => _addNote(doc),
                                        icon: const Icon(Icons.note_alt_outlined),
                                        label: const Text('Notes'),
                                      ),
                                      const SizedBox(width: 6),
                                      if (status != 'acknowledged')
                                        OutlinedButton.icon(
                                          onPressed: () => _markPrayed(doc),
                                          icon: const Icon(Icons.volunteer_activism),
                                          label: const Text('Acknowledge'),
                                        ),
                                      if (status == 'acknowledged' || status == 'new') ...[
                                        const SizedBox(width: 6),
                                        OutlinedButton.icon(
                                          onPressed: () => _archive(doc),
                                          icon: const Icon(Icons.archive_outlined),
                                          label: const Text('Archive'),
                                        ),
                                      ],
                                      if (status == 'archived') ...[
                                        const SizedBox(width: 6),
                                        ElevatedButton.icon(
                                          onPressed: () => _restore(doc),
                                          icon: const Icon(Icons.unarchive),
                                          label: const Text('Restore'),
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      if (!forwarded)
                                        OutlinedButton.icon(
                                          onPressed: () => _forwardToPrayerTower(doc),
                                          icon: const Icon(Icons.forward_to_inbox),
                                          label: const Text('Forward'),
                                        )
                                      else
                                        const Chip(
                                          label: Text('Forwarded to Prayer Tower'),
                                          avatar: Icon(Icons.check, size: 16),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _countChip(String label, int count, {required bool selected, required VoidCallback onTap}) {
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
