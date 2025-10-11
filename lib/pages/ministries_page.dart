import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart';

/// Firestore paths – adjust to match your app if needed
class FP {
  static const users = 'users';
  static const members = 'members';
  static const ministries = 'ministries';
  static const joinRequests = 'join_requests';
}

class MinistresPage extends StatefulWidget {
  const MinistresPage({super.key});

  @override
  State<MinistresPage> createState() => _MinistresPageState();
}

class _MinistresPageState extends State<MinistresPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _uid;
  String? _memberId;
  Set<String> _userRoles = {};
  Set<String> _userMinistries = {};
  bool _loading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      setState(() {
        _loading = false;
      });
      return;
    }
    try {
      final userSnap = await _db.collection(FP.users).doc(uid).get();
      final userData = userSnap.data() ?? {};
      final memberId = userData['memberId'] as String?;
      final rolesList = (userData['roles'] is List) ? List<String>.from(userData['roles']) : <String>[];

      Set<String> roles = rolesList.map((e) => (e ?? '').toString()).toSet();

      Set<String> ministries = {};
      if (memberId != null) {
        final memberSnap = await _db.collection(FP.members).doc(memberId).get();
        final m = memberSnap.data() ?? {};
        final mins = (m['ministries'] is List) ? List<String>.from(m['ministries']) : <String>[];
        ministries = mins.toSet();
      }

      setState(() {
        _uid = uid;
        _memberId = memberId;
        _userRoles = roles;
        _userMinistries = ministries;
        _loading = false;
      });
    } catch (e) {
      setState(() { _loading = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load profile: $e'))
        );
      }
    }
  }

  bool get isAdmin {
    final r = _userRoles.map((e) => e.toLowerCase()).toSet();
    return r.contains('admin');
  }

  bool get isPastor {
    final r = _userRoles.map((e) => e.toLowerCase()).toSet();
    return r.contains('pastor');
  }

  bool _isMemberOf(String ministryId) {
    return _userMinistries.contains(ministryId);
  }

  Future<String?> _pendingJoinStatus(String ministryId) async {
    if (_memberId == null) return null;
    final q = await _db.collection(FP.joinRequests)
        .where('memberId', isEqualTo: _memberId)
        .where('ministryId', isEqualTo: ministryId)
        .orderBy('createdAt', descending: true)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return null;
    return (q.docs.first.data()['status'] as String?) ?? 'pending';
  }

  Future<void> _openJoinBottomSheet(String ministryId, String ministryName) async {
    if (_memberId == null || _uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to request to join.')),
      );
      return;
    }

    final controller = TextEditingController();
    String urgency = 'normal';

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final viewInsets = MediaQuery.of(ctx).viewInsets;
        return Padding(
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.group_add),
                title: Text('Request to join $ministryName', style: Theme.of(ctx).textTheme.titleMedium),
                subtitle: const Text('This will notify ministry leaders for approval.'),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: controller,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Why do you want to join? (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Urgency:'),
                        const SizedBox(width: 12),
                        StatefulBuilder(
                          builder: (ctx2, setSB) => Row(
                            children: [
                              ChoiceChip(
                                label: const Text('Normal'),
                                selected: urgency == 'normal',
                                onSelected: (_) => setSB(() => urgency = 'normal'),
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                label: const Text('High'),
                                selected: urgency == 'high',
                                onSelected: (_) => setSB(() => urgency = 'high'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.send),
                        label: const Text('Send request'),
                        onPressed: () => Navigator.of(ctx).pop(true),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    if (result != true) return;

    try {
      await _db.collection(FP.joinRequests).add({
        'memberId': _memberId,
        'ministryId': ministryId,
        'requestedByUid': _uid,
        'message': controller.text.trim().isEmpty ? null : controller.text.trim(),
        'urgency': urgency,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_outline),
                SizedBox(width: 8),
                Expanded(child: Text('Join request sent. You’ll be notified when approved.')),
              ],
            ),
          ),
        );
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send request: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ministries'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: 240,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search ministries...',
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _db.collection(FP.ministries).orderBy('name').snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final docs = snap.data?.docs ?? [];
          final filtered = docs.where((d) {
            if (_search.isEmpty) return true;
            final name = (d.data()['name'] ?? '').toString().toLowerCase();
            return name.contains(_search);
          }).toList();

          if (filtered.isEmpty) {
            return const Center(child: Text('No ministries found.'));
          }

          return ListView.separated(
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 0),
            itemBuilder: (context, i) {
              final d = filtered[i];
              final data = d.data();
              final id = d.id;
              final name = (data['name'] ?? 'Untitled').toString();
              final description = (data['description'] ?? '').toString();
              final createdAt = data['createdAt'];
              final createdStr = createdAt is Timestamp
                  ? DateFormat('d MMM y • HH:mm').format(createdAt.toDate())
                  : null;

              final amMember = _isMemberOf(id);

              return FutureBuilder<String?>(
                future: _pendingJoinStatus(id),
                builder: (context, statusSnap) {
                  final status = statusSnap.data; // null | pending | approved | declined

                  return ListTile(
                    title: Row(
                      children: [
                        Text(name, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(width: 8),
                        if (status == 'pending') const _StatusChip(label: 'Request pending'),
                        if (status == 'declined') const _StatusChip(label: 'Request declined'),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (description.isNotEmpty) Text(description, maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (createdStr != null) Text(createdStr, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    trailing: _buildActionButton(id, name, amMember, status),
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => MinistryDetailsPage(ministryId: id, ministryName: name),
                      ));
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildActionButton(String ministryId, String ministryName, bool amMember, String? status) {
    // Pastors/Admins have access to all ministries -> show "Open"
    if (isAdmin || isPastor) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open'),
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => MinistryDetailsPage(ministryId: ministryId, ministryName: ministryName),
          ));
        },
      );
    }

    // If already a member -> "View"
    if (amMember) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.visibility_outlined),
        label: const Text('View'),
        onPressed: () {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => MinistryDetailsPage(ministryId: ministryId, ministryName: ministryName),
          ));
        },
      );
    }

    // Not a member: show Join (unless a pending request already exists)
    if (status == 'pending') {
      return const SizedBox.shrink();
    }

    return FilledButton.icon(
      icon: const Icon(Icons.group_add),
      label: const Text('Join'),
      onPressed: () => _openJoinBottomSheet(ministryId, ministryName),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  const _StatusChip({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
