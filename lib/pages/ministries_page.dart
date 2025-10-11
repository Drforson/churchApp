import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import 'ministries_details_page.dart';

/// Firestore paths
class FP {
  static const users = 'users';
  static const members = 'members';
  static const ministries = 'ministries';
  static const joinRequests = 'join_requests';
  static const notifications = 'notifications';
}

class MinistresPage extends StatefulWidget {
  const MinistresPage({super.key});

  @override
  State<MinistresPage> createState() => _MinistresPageState();
}

class _MinistresPageState extends State<MinistresPage>
    with SingleTickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _uid;
  String? _memberId;
  Set<String> _userRoles = {};
  /// Stores **ministry names** (not ids) to match Members schema.
  Set<String> _memberMinistryNames = {};
  bool _loading = true;

  late final TabController _tab;
  String _search = '';

  /// Track busy state per ministry (by name) to avoid double actions.
  final Set<String> _busyMinistryNames = {};

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this); // My / Other
    _bootstrap();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final userSnap = await _db.collection(FP.users).doc(uid).get();
      final user = userSnap.data() ?? {};
      final memberId = user['memberId'] as String?;
      final rolesList = (user['roles'] is List) ? List<String>.from(user['roles']) : <String>[];

      Set<String> ministriesByName = {};
      if (memberId != null) {
        final memberSnap = await _db.collection(FP.members).doc(memberId).get();
        final m = memberSnap.data() ?? {};
        ministriesByName = (m['ministries'] is List) ? Set<String>.from(m['ministries']) : <String>{};
      }

      setState(() {
        _uid = uid;
        _memberId = memberId;
        _userRoles = rolesList.toSet();
        _memberMinistryNames = ministriesByName;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load profile: $e')),
      );
    }
  }

  bool get isAdmin => _userRoles.map((e) => e.toLowerCase()).contains('admin');
  bool get isPastor => _userRoles.map((e) => e.toLowerCase()).contains('pastor');

  bool _isMemberOfByName(String ministryName) => _memberMinistryNames.contains(ministryName);

  /// Latest status for current user + ministry name
  Future<Map<String, String?>?> _latestJoinFor(String ministryName) async {
    if (_memberId == null) return null;
    final q = await _db.collection(FP.joinRequests)
        .where('memberId', isEqualTo: _memberId)
        .where('ministryId', isEqualTo: ministryName)
        .orderBy('requestedAt', descending: true)
        .limit(1)
        .get();
    if (q.docs.isEmpty) return null;
    final data = q.docs.first.data();
    return {
      'status': (data['status'] as String?)?.toLowerCase(), // pending/approved/rejected
      'id': q.docs.first.id,
    };
  }

  Future<void> _showBlockedDialog(String ministryName) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text("Access blocked"),
        content: Text('You can only access "$ministryName" after you’ve joined in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Send notifications:
  /// - A broadcast for leaders (ministryId + leadersOnly)
  /// - Direct per-leader notifications (if we can resolve their uids)
  Future<void> _notifyLeadersOnJoin(String ministryName, String joinRequestId) async {
    try {
      // Broadcast notification leaders can read by ministryId
      await _db.collection(FP.notifications).add({
        'type': 'join_request',
        'ministryId': ministryName,       // NAME for leader filters
        'joinRequestId': joinRequestId,
        'createdAt': FieldValue.serverTimestamp(),
        'audience': {'leadersOnly': true, 'adminAlso': true},
      });

      // Try to fan-out to individual leaders (resolve members -> users)
      final leaders = await _db.collection(FP.members)
          .where('leadershipMinistries', arrayContains: ministryName)
          .get();

      if (leaders.docs.isEmpty) return;

      final batch = _db.batch();
      for (final lm in leaders.docs) {
        final memberId = lm.id;
        final userQs = await _db.collection(FP.users)
            .where('memberId', isEqualTo: memberId)
            .limit(1)
            .get();
        if (userQs.docs.isEmpty) continue;
        final leaderUid = userQs.docs.first.id;

        final ref = _db.collection(FP.notifications).doc();
        batch.set(ref, {
          'type': 'join_request',
          'ministryId': ministryName,
          'joinRequestId': joinRequestId,
          'recipientUid': leaderUid,
          'createdAt': FieldValue.serverTimestamp(),
          'audience': {'direct': true, 'role': 'leader'},
        });
      }
      await batch.commit();
    } catch (_) {
      // swallow – notifications are best-effort
    }
  }

  Future<void> _openJoinBottomSheet(String ministryName) async {
    if (_memberId == null || _uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to request to join.')),
      );
      return;
    }

    final controller = TextEditingController();
    String urgency = 'normal';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final insets = MediaQuery.of(ctx).viewInsets;
        return Padding(
          padding: EdgeInsets.only(bottom: insets.bottom),
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

    if (ok != true) return;

    try {
      // 1) create join request
      final jrRef = await _db.collection(FP.joinRequests).add({
        'memberId': _memberId,
        // Store the NAME, to match member.ministries array & rules
        'ministryId': ministryName,
        'requestedByUid': _uid,
        'message': controller.text.trim().isEmpty ? null : controller.text.trim(),
        'urgency': urgency,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });

      // 2) notify leaders
      await _notifyLeadersOnJoin(ministryName, jrRef.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline),
              SizedBox(width: 8),
              Expanded(child: Text('Join request sent. Leaders have been notified.')),
            ],
          ),
        ),
      );
      setState(() {}); // let FutureBuilders refresh
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send request: $e')),
      );
    }
  }

  Future<void> _cancelPendingRequest(String requestId) async {
    if (requestId.isEmpty) return;
    try {
      await _db.collection(FP.joinRequests).doc(requestId).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join request cancelled.')),
      );
      setState(() {}); // refresh status
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to cancel: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ministries'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'My ministries'),
            Tab(text: 'Other ministries'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: 260,
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
          final allDocs = (snap.data?.docs ?? []).where((d) {
            if (_search.isEmpty) return true;
            final name = (d.data()['name'] ?? '').toString().toLowerCase();
            return name.contains(_search);
          }).toList();

          final my = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
          final other = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

          for (final d in allDocs) {
            final name = (d.data()['name'] ?? '').toString();
            if (_isMemberOfByName(name)) {
              my.add(d);
            } else {
              other.add(d);
            }
          }

          return TabBarView(
            controller: _tab,
            children: [
              _buildList(context, my, isOtherTab: false),
              _buildList(context, other, isOtherTab: true),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(BuildContext context,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      {required bool isOtherTab}) {
    if (docs.isEmpty) {
      return Center(child: Text(isOtherTab ? 'No other ministries.' : 'You are not in any ministries yet.'));
    }
    return ListView.separated(
      itemCount: docs.length,
      separatorBuilder: (_, __) => const Divider(height: 0),
      itemBuilder: (context, i) {
        final d = docs[i];
        final data = d.data();
        final id = d.id;
        final name = (data['name'] ?? 'Untitled').toString();
        final description = (data['description'] ?? '').toString();
        final createdAt = data['createdAt'];
        final createdStr = createdAt is Timestamp
            ? DateFormat('d MMM y • HH:mm').format(createdAt.toDate())
            : null;

        final amMember = _isMemberOfByName(name);

        // Future builder for status & latest request id for this user+ministry
        return FutureBuilder<Map<String, String?>?>(
          future: _latestJoinFor(name),
          builder: (context, statusSnap) {
            final latest = statusSnap.data;
            final status = latest?['status']; // pending | approved | rejected | null
            final reqId = latest?['id'] ?? '';

            // GREY OUT non-member tiles (unless admin/pastor)
            final locked = !amMember && !isAdmin && !isPastor;

            final tile = ListTile(
              enabled: !locked, // visually dims splash focus, but we also control opacity
              title: Row(
                children: [
                  Text(name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  if (status == 'pending') const _StatusChip(label: 'Request pending'),
                  if (status == 'rejected') const _StatusChip(label: 'Request declined'),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (description.isNotEmpty) Text(description, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (createdStr != null) Text(createdStr, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              trailing: _buildActionButton(
                ministryId: id,
                ministryName: name,
                amMember: amMember,
                status: status,
                requestId: reqId,
              ),
              onTap: () async {
                if (isAdmin || isPastor || amMember) {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => MinistryDetailsPage(ministryId: id, ministryName: name),
                  ));
                } else {
                  await _showBlockedDialog(name);
                }
              },
            );

            if (!locked) return tile;

            // Greyed out visual with tap still intercepted -> shows popup
            return Opacity(
              opacity: 0.55,
              child: AbsorbPointer(
                // Absorb the tile built-in tap ripple, we manually handle via onTap above
                absorbing: false,
                child: tile,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildActionButton({
    required String ministryId,
    required String ministryName,
    required bool amMember,
    required String? status,
    required String requestId,
  }) {
    // Admins/Pastors: full access — Open
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

    // Already a member: View
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

    // Not a member: single toggle button (Join <-> Cancel)
    return _joinCancelToggleButton(
      ministryName: ministryName,
      pending: status == 'pending',
      requestId: requestId,
    );
  }

  Widget _joinCancelToggleButton({
    required String ministryName,
    required bool pending,
    required String requestId,
  }) {
    final busy = _busyMinistryNames.contains(ministryName);
    final label = pending ? 'Cancel' : 'Join';
    final icon = pending ? Icons.undo : Icons.group_add;

    return FilledButton.icon(
      icon: busy
          ? const SizedBox(
        width: 16, height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      )
          : Icon(icon),
      label: Text(label),
      onPressed: busy
          ? null
          : () async {
        setState(() => _busyMinistryNames.add(ministryName));
        try {
          if (pending) {
            // Cancel existing pending request
            await _cancelPendingRequest(requestId);
          } else {
            // Create a new join request via bottom sheet
            await _openJoinBottomSheet(ministryName);
          }
        } finally {
          if (mounted) {
            setState(() => _busyMinistryNames.remove(ministryName));
          }
        }
      },
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
