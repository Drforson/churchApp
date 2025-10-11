// lib/pages/ministries_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MinistriesPage extends StatefulWidget {
  const MinistriesPage({super.key});

  @override
  State<MinistriesPage> createState() => _MinistriesPageState();
}

class _MinistriesPageState extends State<MinistriesPage>
    with TickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  bool _loading = true;
  bool _isLeader = false;
  String? _uid;

  // search
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _resolveRole();
    _searchCtrl.addListener(() {
      final v = _searchCtrl.text.trim();
      if (v != _query) {
        setState(() => _query = v);
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _resolveRole() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _uid = null;
        _isLeader = false;
        _loading = false;
      });
      return;
    }
    _uid = user.uid;
    try {
      final u = await _db.collection('users').doc(user.uid).get();
      final data = u.data() ?? {};
      final roles = (data['roles'] is List)
          ? List<String>.from(data['roles'])
          : <String>[];
      final bool isLeader = roles.map((e) => e.toLowerCase()).contains('leader') ||
          (data['isLeader'] == true) ||
          (data['leadershipMinistries'] is List &&
              (data['leadershipMinistries'] as List).isNotEmpty);
      setState(() {
        _isLeader = isLeader;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _isLeader = false;
        _loading = false;
      });
    }
  }

  // -------- New Ministry Request (Leader) --------
  Future<void> _openNewMinistryDialog() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request New Ministry'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Ministry name',
                hintText: 'e.g., Worship Team',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Submit')),
        ],
      ),
    );

    if (ok == true) {
      final name = nameCtrl.text.trim();
      final desc = descCtrl.text.trim();
      await _submitNewRequest(name, desc);
    }
  }

  Future<void> _submitNewRequest(String name, String description) async {
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required.')),
      );
      return;
    }
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      // Optional: enrich with requester identity for nicer Pastor UI
      String? requesterEmail;
      String? requesterFullName;

      final u = await _db.collection('users').doc(uid).get();
      final data = u.data() ?? {};
      requesterEmail = (data['email'] ?? '').toString();

      final memberId = (data['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        final m = await _db.collection('members').doc(memberId).get();
        final md = m.data() ?? {};
        final fullField = (md['fullName'] ?? '').toString().trim();
        final fn = (md['firstName'] ?? '').toString().trim();
        final ln = (md['lastName'] ?? '').toString().trim();
        final full = fullField.isNotEmpty
            ? fullField
            : [fn, ln].where((s) => s.isNotEmpty).join(' ').trim();
        if (full.isNotEmpty) requesterFullName = full;
      }

      await _db.collection('ministry_creation_requests').add({
        'ministryName': name,
        'name': name,
        'description': description,
        'requestedByUid': uid,
        'requesterEmail': requesterEmail,
        'requesterFullName': requesterFullName,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request submitted. A Pastor will review it.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error submitting request: $e')),
      );
    }
  }

  // -------- Data streams --------

  Stream<List<Map<String, dynamic>>> _ministriesStream() {
    // Basic ministries list. If you persist a "name" field (recommended).
    final base = _db.collection('ministries').orderBy('name');
    return base.snapshots().map((qs) {
      final list = qs.docs.map((d) {
        final data = d.data() as Map<String, dynamic>;
        return {
          'id': d.id,
          'name': (data['name'] ?? '').toString(),
          'description': (data['description'] ?? '').toString(),
          'createdAt': data['createdAt'],
        };
      }).toList();

      if (_query.isEmpty) return list;
      final q = _query.toLowerCase();
      return list
          .where((m) =>
      (m['name'] as String).toLowerCase().contains(q) ||
          (m['description'] as String).toLowerCase().contains(q))
          .toList();
    });
  }

  Stream<List<Map<String, dynamic>>> _myRequestsStream() {
    if (_uid == null) return const Stream.empty();
    final q = _db
        .collection('ministry_creation_requests')
        .where('requestedByUid', isEqualTo: _uid)
        .orderBy('requestedAt', descending: true);
    return q.snapshots().map((qs) {
      return qs.docs.map((d) {
        final data = d.data() as Map<String, dynamic>;
        return {
          'id': d.id,
          'name': (data['name'] ?? data['ministryName'] ?? '').toString(),
          'description': (data['description'] ?? '').toString(),
          'status': (data['status'] ?? 'pending').toString().toLowerCase(),
          'requestedAt': data['requestedAt'],
          'approvedAt': data['approvedAt'],
        };
      }).toList();
    });
  }

  // -------- UI helpers --------

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return Colors.green;
      case 'declined':
      case 'rejected':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  Widget _statusChip(String status) {
    final color = _statusColor(status);
    return Chip(
      label: Text(status[0].toUpperCase() + status.substring(1)),
      backgroundColor: color.withOpacity(0.12),
      labelStyle: TextStyle(color: color),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color.withOpacity(0.4)),
    );
  }

  Future<void> _cancelPending(String requestId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel request?'),
        content: const Text('This will delete your pending request.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes, cancel')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _db.collection('ministry_creation_requests').doc(requestId).delete();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request cancelled.')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error cancelling: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final tabs = <Tab>[const Tab(text: 'Ministries')];
    if (_isLeader) tabs.add(const Tab(text: 'My Requests'));

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ministries'),
          bottom: TabBar(tabs: tabs),
          actions: [
            // Search field (simple inline)
            SizedBox(
              width: 220,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search ministries…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    suffixIcon: _query.isEmpty
                        ? const Icon(Icons.search)
                        : IconButton(
                      onPressed: () => _searchCtrl.clear(),
                      icon: const Icon(Icons.clear),
                    ),
                  ),
                ),
              ),
            ),
            if (_isLeader)
              IconButton(
                tooltip: 'Request New Ministry',
                onPressed: _openNewMinistryDialog,
                icon: const Icon(Icons.add_box),
              ),
          ],
        ),
        floatingActionButton: _isLeader
            ? FloatingActionButton(
          tooltip: 'Request New Ministry',
          onPressed: _openNewMinistryDialog,
          child: const Icon(Icons.add),
        )
            : null,
        body: TabBarView(
          children: [
            // ---- Tab 1: Ministries ----
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _ministriesStream(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final items = snap.data!;
                if (items.isEmpty) {
                  return const Center(child: Text('No ministries yet.'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final m = items[i];
                    final ts = m['createdAt'];
                    final createdAt = ts is Timestamp ? ts.toDate() : null;
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.groups),
                        title: Text((m['name'] as String).isEmpty ? 'Unnamed Ministry' : m['name'] as String),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if ((m['description'] as String).isNotEmpty)
                              Text(m['description'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
                            if (createdAt != null)
                              Text('Created: ${createdAt.toLocal()}',
                                  style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        onTap: () {
                          // TODO: navigate to MinistryDetailsPage if desired
                          // Navigator.push(context, MaterialPageRoute(builder: (_) => MinistryDetailsPage(...)));
                        },
                      ),
                    );
                  },
                );
              },
            ),

            // ---- Tab 2: My Requests (only for leaders) ----
            if (_isLeader)
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _myRequestsStream(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final reqs = snap.data!;
                  if (reqs.isEmpty) {
                    return const Center(child: Text('You have no requests yet.'));
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: reqs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = reqs[i];
                      final status = (r['status'] as String).toLowerCase();
                      final ts = r['requestedAt'];
                      final requestedAt = ts is Timestamp ? ts.toDate() : null;

                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      (r['name'] as String).isEmpty ? 'Unnamed Ministry' : r['name'] as String,
                                      style: Theme.of(context).textTheme.titleMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  _statusChip(status),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if ((r['description'] as String).isNotEmpty)
                                Text(r['description'] as String,
                                    maxLines: 3, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 6),
                              if (requestedAt != null)
                                Text(
                                  'Requested: ${requestedAt.toLocal()}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (status == 'pending')
                                    TextButton.icon(
                                      onPressed: () => _cancelPending(r['id'] as String),
                                      icon: const Icon(Icons.cancel),
                                      label: const Text('Cancel'),
                                    )
                                  else
                                    const SizedBox.shrink(),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
