// lib/pages/ministry_details_page.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/firestore_paths.dart';
import 'ministry_feed_page.dart';

class MinistryDetailsPage extends StatefulWidget {
  final String ministryId;   // ministries/{docId}
  final String ministryName; // human-readable name used across membership arrays

  const MinistryDetailsPage({
    super.key,
    required this.ministryId,
    required this.ministryName,
  });

  @override
  State<MinistryDetailsPage> createState() => _MinistryDetailsPageState();
}

class _MinistryDetailsPageState extends State<MinistryDetailsPage>
    with TickerProviderStateMixin {
  late final TabController _tab;

  bool _loading = true;
  String? _uid;
  String? _memberId;
  Set<String> _roles = {};
  Set<String> _memberMinistriesByName = {};
  String? _latestJoinStatus; // pending / approved / rejected / null
  bool _canAccess = false;   // computed gate

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this); // Members / Feed / Overview
    _bootstrap();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final auth = FirebaseAuth.instance;
      final db = FirebaseFirestore.instance;
      _uid = auth.currentUser?.uid;

      if (_uid == null) {
        setState(() {
          _loading = false;
          _canAccess = false;
        });
        return;
      }

      final userSnap = await db.collection(FP.users).doc(_uid).get();
      final u = userSnap.data() ?? {};
      _memberId = (u['memberId'] is String) ? u['memberId'] as String : null;
      _roles = (u['roles'] is List) ? Set<String>.from(u['roles']) : <String>{};

      if (_memberId != null) {
        final memSnap = await db.collection(FP.members).doc(_memberId).get();
        final m = memSnap.data() ?? {};
        _memberMinistriesByName = (m['ministries'] is List)
            ? Set<String>.from(m['ministries'])
            : <String>{};
      }

      // Compute access: admin/pastor OR member of ministry by NAME
      final rolesLower = _roles.map((e) => e.toLowerCase()).toSet();
      final isAdmin = rolesLower.contains('admin');
      final isPastor = rolesLower.contains('pastor');
      final isMemberHere = _memberMinistriesByName.contains(widget.ministryName);

      _canAccess = isAdmin || isPastor || isMemberHere;

      // Latest join status (for banner if needed)
      if (_memberId != null) {
        final q = await db.collection(FP.joinRequests)
            .where('memberId', isEqualTo: _memberId)
            .where('ministryId', isEqualTo: widget.ministryName) // NAME
            .orderBy('requestedAt', descending: true)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          _latestJoinStatus = (q.docs.first.data()['status'] as String?)?.toLowerCase();
        }
      }

      setState(() {
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _canAccess = false;
      });
    }
  }

  Future<void> _openJoinBottomSheet() async {
    if (_uid == null || _memberId == null) return;
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
                title: Text('Request to join ${widget.ministryName}', style: Theme.of(ctx).textTheme.titleMedium),
                subtitle: const Text('This will notify ministry leaders for approval.'),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: controller,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Why do you want to join? (optional)',
                    border: OutlineInputBorder(),
                  ),
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
      await FirebaseFirestore.instance.collection(FP.joinRequests).add({
        'memberId': _memberId,
        'ministryId': widget.ministryName, // NAME for consistency
        'requestedByUid': _uid,
        'message': controller.text.trim().isEmpty ? null : controller.text.trim(),
        'urgency': 'normal',
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        setState(() => _latestJoinStatus = 'pending');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Join request sent.')),
        );
      }
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // If no access: show a locked screen; do NOT expose ministry content
    if (!_canAccess) {
      final canRequest =
          _uid != null &&
              !(_roles.map((e) => e.toLowerCase()).contains('admin')) &&
              !(_roles.map((e) => e.toLowerCase()).contains('pastor')) &&
              !_memberMinistriesByName.contains(widget.ministryName) &&
              _latestJoinStatus != 'pending';

      return Scaffold(
        appBar: AppBar(title: Text(widget.ministryName)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 12),
                const Text(
                  "You don't have access to this ministry yet.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                if (_latestJoinStatus == 'pending')
                  const Text('Your join request is pending approval.',
                      style: TextStyle(fontStyle: FontStyle.italic)),
                const SizedBox(height: 16),
                if (canRequest)
                  FilledButton.icon(
                    icon: const Icon(Icons.group_add),
                    label: const Text('Request to join'),
                    onPressed: _openJoinBottomSheet,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // If access is granted, show the real content with tabs
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ministryName),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Members'),
            Tab(text: 'Feed'),
            Tab(text: 'Overview'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MembersTab(ministryName: widget.ministryName, ministryId: widget.ministryId),
          MinistryFeedPage(ministryId: widget.ministryId, ministryName: widget.ministryName),
          _OverviewTab(ministryId: widget.ministryId, ministryName: widget.ministryName),
        ],
      ),
    );
  }
}

// Simple Members Tab (unchanged in logic for access)
class _MembersTab extends StatelessWidget {
  final String ministryId;
  final String ministryName;
  const _MembersTab({required this.ministryId, required this.ministryName});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;

    Stream<List<Map<String, dynamic>>> _membersStream() {
      return db
          .collection(FP.members)
          .where('ministries', arrayContains: ministryName)
          .snapshots()
          .map((snap) {
        return snap.docs.map((d) {
          final data = d.data();
          final first = (data['firstName'] ?? '').toString();
          final last = (data['lastName'] ?? '').toString();
          final name = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
          final email = (data['email'] ?? '').toString();
          return {
            'memberId': d.id,
            'name': name.isEmpty ? 'Unnamed Member' : name,
            'email': email,
          };
        }).toList();
      });
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _membersStream(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final members = snap.data!;
        if (members.isEmpty) return const Center(child: Text('No members yet.'));
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: members.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final m = members[i];
            return Card(
              child: ListTile(
                title: Text(m['name'] ?? 'Unnamed Member'),
                subtitle: Text(m['email'] ?? ''),
              ),
            );
          },
        );
      },
    );
  }
}

class _OverviewTab extends StatelessWidget {
  final String ministryId;
  final String ministryName;
  const _OverviewTab({required this.ministryId, required this.ministryName});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;

    final membersQ = db
        .collection(FP.members)
        .where('ministries', arrayContains: ministryName);

    final leadersQ = db
        .collection(FP.members)
        .where('leadershipMinistries', arrayContains: ministryName);

    final postsQ = db
        .collection(FP.ministries)
        .doc(ministryId)
        .collection('posts')
        .orderBy('createdAt', descending: true)
        .limit(5);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          FutureBuilder<QuerySnapshot>(
            future: membersQ.get(),
            builder: (context, snap) {
              final count = snap.data?.docs.length ?? 0;
              return _StatCard(label: 'Members', value: count.toString());
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<QuerySnapshot>(
            future: leadersQ.get(),
            builder: (context, snap) {
              final count = snap.data?.docs.length ?? 0;
              return _StatCard(label: 'Leaders', value: count.toString());
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Recent Posts', style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot>(
            stream: postsQ.snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Text('No posts yet.');
              }
              return Column(
                children: docs.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final title = (data['title'] ?? 'Untitled').toString();
                  final createdAt = (data['createdAt'] is Timestamp)
                      ? (data['createdAt'] as Timestamp).toDate()
                      : null;
                  final when = createdAt != null
                      ? DateFormat('dd MMM yyyy, HH:mm').format(createdAt)
                      : '—';
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.article),
                    title: Text(title),
                    subtitle: Text('Posted: $when'),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Text(label, style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(value, style: theme.textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}
