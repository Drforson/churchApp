import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class DebugAdminSetterPage extends StatefulWidget {
  const DebugAdminSetterPage({super.key});

  @override
  State<DebugAdminSetterPage> createState() => _DebugAdminSetterPageState();
}

class _DebugAdminSetterPageState extends State<DebugAdminSetterPage>
    with SingleTickerProviderStateMixin {
  // ======= Existing state (unchanged) =======
  String? _userId;
  String? _linkedMemberId;
  String? _linkedMemberName;
  bool _isLeader = false;
  List<String> _rolesFromUsers = [];
  List<String> _rolesFromMembers = [];
  List<String> _leadershipMinistriesFromUsers = [];
  List<String> _leadershipMinistriesFromMembers = [];
  bool _loading = false;

  // Pastor role manager (existing)
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String _searchError = '';
  List<_MemberResult> _searchResults = [];

  bool get _isAdminNow =>
      _rolesFromUsers.map((e) => e.toLowerCase()).contains('admin') ||
          _rolesFromMembers.map((e) => e.toLowerCase()).contains('admin');

  // ======= NEW: tabs =======
  late final TabController _tabController;

  // ======= NEW: Grant Permissions tab state =======
  final TextEditingController _grantSearchCtrl = TextEditingController();
  String _grantQuery = '';
  final Set<String> _selectedMemberIds = <String>{};
  final Set<String> _rolesToGrant = <String>{}; // {pastor, usher, media}
  final Set<String> _rolesToRemove = <String>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchUserData();

    // Debounce for pastor search (existing)
    _searchCtrl.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        _runSearch(_searchCtrl.text.trim());
      });
    });

    // Grant search text
    _grantSearchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _grantQuery = _grantSearchCtrl.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _grantSearchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ======= Existing helpers (unchanged logic) =======
  Future<void> _fetchUserData() async {
    setState(() => _loading = true);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }

    final userId = user.uid;
    final userDoc =
    await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final userData = userDoc.data();

    if (userData != null) {
      final memberId = userData['memberId'];
      final rolesFromUsers = List<String>.from(userData['roles'] ?? []);
      final leadershipMinistriesFromUsers =
      List<String>.from(userData['leadershipMinistries'] ?? []);

      List<String> rolesFromMembers = [];
      List<String> leadershipMinistriesFromMembers = [];
      String? fullName;
      bool isLeader = false;

      bool updated = false;

      if (memberId != null) {
        final memberDoc = await FirebaseFirestore.instance
            .collection('members')
            .doc(memberId)
            .get();
        if (memberDoc.exists) {
          final memberData = memberDoc.data();
          rolesFromMembers = List<String>.from(memberData?['roles'] ?? []);
          leadershipMinistriesFromMembers =
          List<String>.from(memberData?['leadershipMinistries'] ?? []);
          fullName =
              "${memberData?['firstName'] ?? ''} ${memberData?['lastName'] ?? ''}"
                  .trim();
          isLeader = leadershipMinistriesFromMembers.isNotEmpty;

          // Merge roles + leadershipMinistries back to users doc
          final mergedRoles = {...rolesFromUsers, ...rolesFromMembers}.toList();
          final mergedMin = {
            ...leadershipMinistriesFromUsers,
            ...leadershipMinistriesFromMembers
          }.toList();

          if (mergedRoles.length != rolesFromUsers.length ||
              mergedMin.length != leadershipMinistriesFromUsers.length) {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(userId)
                .set({
              'roles': mergedRoles,
              'leadershipMinistries': mergedMin,
            }, SetOptions(merge: true));
            updated = true;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _userId = userId;
        _linkedMemberId = memberId;
        _rolesFromUsers = rolesFromUsers;
        _rolesFromMembers = rolesFromMembers;
        _leadershipMinistriesFromUsers = leadershipMinistriesFromUsers;
        _leadershipMinistriesFromMembers = leadershipMinistriesFromMembers;
        _linkedMemberName =
        (fullName == null || fullName.isEmpty) ? null : fullName;
        _isLeader = isLeader || leadershipMinistriesFromUsers.isNotEmpty;
        _loading = false;
      });

      if (updated && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Roles and Leadership Ministries updated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }

      await _syncLeaderRole();
    } else {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<Set<String>> _discoverLeadershipFromMinistriesCollection(String uid) async {
    final qs = await FirebaseFirestore.instance
        .collection('ministries')
        .where('leaderIds', arrayContains: uid)
        .get();

    final names = <String>{};
    for (final d in qs.docs) {
      final data = d.data();
      final name = (data['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) {
        names.add(name);
      }
    }
    return names;
  }

  Future<void> _syncLeaderRole() async {
    if (_userId == null) return;

    try {
      final userMin = _leadershipMinistriesFromUsers.toSet();
      final memberMin = _leadershipMinistriesFromMembers.toSet();
      final discovered = await _discoverLeadershipFromMinistriesCollection(_userId!);

      final unified = <String>{...userMin, ...memberMin, ...discovered};

      if (unified.isEmpty) return;

      await FirebaseFirestore.instance.collection('users').doc(_userId).set({
        'roles': FieldValue.arrayUnion(['leader']),
        'leadershipMinistries': unified.toList(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        if (!_rolesFromUsers.contains('leader')) {
          _rolesFromUsers = [..._rolesFromUsers, 'leader'];
        }
        _leadershipMinistriesFromUsers = unified.toList();
        _isLeader = true;
      });

      if (_linkedMemberId != null) {
        try {
          final callable = FirebaseFunctions.instance.httpsCallable(
            'ensureMemberLeaderRole',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
          );
          await callable.call(<String, dynamic>{'memberId': _linkedMemberId});
        } catch (_) {}
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Leader role synced')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Leader sync failed: $e')),
        );
      }
    }
  }

  Future<void> _setAdminRole() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in first.')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'promoteMeToAdmin',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
      );
      await callable.call(<String, dynamic>{});

      await _fetchUserData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Promoted to Admin')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Promote failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeAdminRole() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userId = user.uid;
    final userDoc =
    await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final memberId = userDoc.data()?['memberId'];

    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .update({'roles': FieldValue.arrayRemove(['admin'])});

    if (memberId != null) {
      await FirebaseFirestore.instance
          .collection('members')
          .doc(memberId)
          .update({'roles': FieldValue.arrayRemove(['admin'])});
    }

    await _fetchUserData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("✅ Admin role removed")),
    );
  }

  Future<void> _linkUserToMember() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userEmail = user.email;
    if (userEmail == null) return;

    final memberQuery = await FirebaseFirestore.instance
        .collection('members')
        .where('email', isEqualTo: userEmail)
        .limit(1)
        .get();

    if (memberQuery.docs.isNotEmpty) {
      final memberDoc = memberQuery.docs.first;
      final memberId = memberDoc.id;
      final memberData = memberDoc.data();
      final fullName =
      "${memberData['firstName'] ?? ''} ${memberData['lastName'] ?? ''}".trim();
      final leadershipMinistries =
      List<String>.from(memberData['leadershipMinistries'] ?? []);
      final isLeader = leadershipMinistries.isNotEmpty;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'memberId': memberId});

      if (!mounted) return;
      setState(() {
        _linkedMemberId = memberId;
        _linkedMemberName = fullName.isEmpty ? 'Unnamed Member' : fullName;
        _isLeader = isLeader;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("✅ User linked to member: $_linkedMemberName")),
      );

      await _fetchUserData();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ No member found with this email")),
      );
    }
  }

  // ===== Pastor role search (existing) =====
  Future<void> _runSearch(String query) async {
    if (!_isAdminNow) return;
    setState(() {
      _searching = true;
      _searchError = '';
      _searchResults = [];
    });

    try {
      final col = FirebaseFirestore.instance.collection('members');
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];

      if (query.isEmpty) {
        docs = [];
      } else if (query.contains('@')) {
        final qs = await col.where('email', isEqualTo: query).limit(10).get();
        docs = qs.docs;
      } else {
        final qLower = query.toLowerCase();
        try {
          final qs = await col
              .orderBy('fullNameLower')
              .startAt([qLower])
              .endAt(['$qLower\uf8ff'])
              .limit(20)
              .get();
          docs = qs.docs;
        } catch (_) {
          final qs = await col.limit(50).get();
          docs = qs.docs.where((d) {
            final data = d.data();
            final first = (data['firstName'] ?? '').toString().toLowerCase();
            final last = (data['lastName'] ?? '').toString().toLowerCase();
            final full = ('$first $last').trim();
            return first.contains(qLower) ||
                last.contains(qLower) ||
                full.contains(qLower);
          }).toList();
        }
      }

      final results = docs.map((d) {
        final data = d.data();
        final roles = List<String>.from(data['roles'] ?? const []);
        final first = (data['firstName'] ?? '').toString();
        final last = (data['lastName'] ?? '').toString();
        final full = (('$first $last').trim().isEmpty
            ? (data['fullName'] ?? '').toString()
            : ('$first $last').trim())
            .trim();
        final email = (data['email'] ?? '').toString();
        final id = d.id;
        return _MemberResult(
          id: id,
          name: full.isEmpty ? 'Unnamed Member' : full,
          email: email,
          roles: roles,
        );
      }).toList();

      setState(() {
        _searchResults = results;
      });
    } catch (e) {
      setState(() => _searchError = 'Search failed: $e');
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _setPastorRoleOnMember(_MemberResult m,
      {required bool makePastor}) async {
    if (!_isAdminNow) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins can modify roles.')),
      );
      return;
    }

    try {
      bool cfWorked = false;
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'setMemberPastorRole',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
        );
        await callable
            .call(<String, dynamic>{'memberId': m.id, 'makePastor': makePastor});
        cfWorked = true;
      } on FirebaseFunctionsException catch (_) {}

      if (!cfWorked) {
        await FirebaseFirestore.instance.collection('members').doc(m.id).update({
          'roles': makePastor
              ? FieldValue.arrayUnion(['pastor'])
              : FieldValue.arrayRemove(['pastor']),
          'isPastor': makePastor,
        });
      }

      final usersQ = await FirebaseFirestore.instance
          .collection('users')
          .where('memberId', isEqualTo: m.id)
          .limit(1)
          .get();

      if (usersQ.docs.isNotEmpty) {
        final uRef = usersQ.docs.first.reference;
        await uRef.update({
          'roles': makePastor
              ? FieldValue.arrayUnion(['pastor'])
              : FieldValue.arrayRemove(['pastor']),
        });
      }

      setState(() {
        final i = _searchResults.indexWhere((r) => r.id == m.id);
        if (i != -1) {
          final updated = List<String>.from(_searchResults[i].roles);
          if (makePastor) {
            if (!updated.contains('pastor')) updated.add('pastor');
          } else {
            updated.removeWhere((r) => r == 'pastor');
          }
          _searchResults[i] = _searchResults[i].copyWith(roles: updated);
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                makePastor ? '✅ Pastor role granted' : '✅ Pastor role removed')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Update failed: $e')),
      );
    }
  }

  // ===== NEW: GRANT PERMISSIONS =====

  Future<void> _bulkApplyRoles({
    required Iterable<String> memberIds,
    required Iterable<String> add,
    required Iterable<String> remove,
  }) async {
    if (!_isAdminNow) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins can modify roles.')),
      );
      return;
    }
    if (memberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one member.')),
      );
      return;
    }

    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'setMemberRoles',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      await callable.call(<String, dynamic>{
        'memberIds': memberIds.toList(),
        'rolesAdd': add.map((e) => e.toLowerCase()).toList(),
        'rolesRemove': remove.map((e) => e.toLowerCase()).toList(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '✅ Updated ${memberIds.length} member(s): +[${add.join(', ')}] -[${remove.join(', ')}]'),
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Cloud Function failed: ${e.code} ${e.message ?? ''}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Update failed: $e')),
      );
    }
  }

  void _toggleRoleToGrant(String role) {
    setState(() {
      final r = role.toLowerCase();
      if (_rolesToGrant.contains(r)) {
        _rolesToGrant.remove(r);
      } else {
        _rolesToGrant.add(r);
        _rolesToRemove.remove(r);
      }
    });
  }

  void _toggleRoleToRemove(String role) {
    setState(() {
      final r = role.toLowerCase();
      if (_rolesToRemove.contains(r)) {
        _rolesToRemove.remove(r);
      } else {
        _rolesToRemove.add(r);
        _rolesToGrant.remove(r);
      }
    });
  }

  // Build a chip toggle row for roles
  Widget _roleChips() {
    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Color? color,
    }) {
      return FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        label: Text(label),
        selectedColor: (color ?? Colors.indigo).withOpacity(0.2),
        checkmarkColor: Colors.indigo,
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        Text('Grant:', style: Theme.of(context).textTheme.labelLarge),
        chip(
          label: 'Pastor',
          selected: _rolesToGrant.contains('pastor'),
          onTap: () => _toggleRoleToGrant('pastor'),
        ),
        chip(
          label: 'Usher',
          selected: _rolesToGrant.contains('usher'),
          onTap: () => _toggleRoleToGrant('usher'),
        ),
        chip(
          label: 'Media',
          selected: _rolesToGrant.contains('media'),
          onTap: () => _toggleRoleToGrant('media'),
        ),
        const SizedBox(width: 16),
        Text('Remove:', style: Theme.of(context).textTheme.labelLarge),
        chip(
          label: 'Pastor',
          selected: _rolesToRemove.contains('pastor'),
          onTap: () => _toggleRoleToRemove('pastor'),
          color: Colors.red,
        ),
        chip(
          label: 'Usher',
          selected: _rolesToRemove.contains('usher'),
          onTap: () => _toggleRoleToRemove('usher'),
          color: Colors.red,
        ),
        chip(
          label: 'Media',
          selected: _rolesToRemove.contains('media'),
          onTap: () => _toggleRoleToRemove('media'),
          color: Colors.red,
        ),
      ],
    );
  }

  // Build the “Grant Permissions” tab using the SAME fetch pattern as ViewMembersPage
  Widget _buildGrantPermissionsTab() {
    return FutureBuilder<QuerySnapshot>(
      future: FirebaseFirestore.instance.collection('members').get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting || _loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final members = snapshot.data?.docs
            .map((e) => {
          ...((e.data() as Map<String, dynamic>?) ?? const {}),
          '_id': e.id,
        })
            .toList() ??
            [];

        // Filter by search text (first+last or fullName)
        List<Map<String, dynamic>> filtered = members.where((m) {
          final first = (m['firstName'] ?? '').toString();
          final last = (m['lastName'] ?? '').toString();
          final fullName = (m['fullName'] ?? '').toString();
          final name =
          (('$first $last').trim().isEmpty ? fullName : '$first $last')
              .toLowerCase();
          if (_grantQuery.isEmpty) return true;
          return name.contains(_grantQuery);
        }).toList();

        // Derive ministries from members (just like ViewMembersPage)
        final Set<String> allMinistries = {};
        for (var m in filtered) {
          final mins = m['ministries'];
          if (mins is List) {
            allMinistries.addAll(mins.map((e) => e.toString()));
          }
        }
        final sortedMinistries = allMinistries.toList()..sort();

        // Members with no ministry
        final List<Map<String, dynamic>> noMinistry = filtered.where((m) {
          final mins = m['ministries'];
          return !(mins is List) || mins.isEmpty;
        }).toList();

        // Colors like your ViewMembersPage style
        final colors = [
          Colors.teal.shade200,
          Colors.orange.shade200,
          Colors.indigo.shade200,
          Colors.purple.shade200,
          Colors.green.shade200,
          Colors.blueGrey.shade200,
          Colors.pink.shade200,
        ];

        int colorIndex = 0;

        return Column(
          children: [
            // Controls row (search + chips + buttons)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Search
                  TextField(
                    controller: _grantSearchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search members by name...',
                      border: const OutlineInputBorder(),
                      suffixIcon: _grantQuery.isNotEmpty
                          ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _grantSearchCtrl.clear(),
                      )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _roleChips(),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.check),
                        label: const Text('Grant selected'),
                        onPressed: _rolesToGrant.isEmpty
                            ? null
                            : () => _bulkApplyRoles(
                          memberIds: _selectedMemberIds,
                          add: _rolesToGrant,
                          remove: const [],
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text('Remove selected'),
                        onPressed: _rolesToRemove.isEmpty
                            ? null
                            : () => _bulkApplyRoles(
                          memberIds: _selectedMemberIds,
                          add: const [],
                          remove: _rolesToRemove,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_selectedMemberIds.length} selected',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Divider(height: 0),

            // List
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  // No-ministry group
                  if (noMinistry.isNotEmpty)
                    _ministryCard(
                      title: 'No Ministry',
                      color: colors[colorIndex++ % colors.length],
                      members: noMinistry,
                    ),

                  // Each ministry group
                  ...sortedMinistries.map((ministryName) {
                    final groupMembers = filtered.where((m) {
                      final mins = m['ministries'];
                      return mins is List &&
                          mins.map((e) => e.toString()).contains(ministryName);
                    }).toList();

                    if (groupMembers.isEmpty) {
                      return const SizedBox.shrink();
                    }

                    final color = colors[colorIndex++ % colors.length];
                    return _ministryCard(
                      title: ministryName,
                      color: color,
                      members: groupMembers,
                    );
                  }),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // A grouped card like ViewMembersPage’s By-Ministry list, but with checkboxes
  Widget _ministryCard({
    required String title,
    required Color color,
    required List<Map<String, dynamic>> members,
  }) {
    final allIds = members.map((m) => m['_id'] as String).toSet();
    final allSelected =
        allIds.isNotEmpty && allIds.difference(_selectedMemberIds).isEmpty;

    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: false,
        title: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$title  •  ${members.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              // Group select toggle
              Checkbox(
                value: allSelected,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedMemberIds.addAll(allIds);
                    } else {
                      _selectedMemberIds.removeAll(allIds);
                    }
                  });
                },
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        children: members.map((m) {
          final id = (m['_id'] ?? '').toString();
          final first = (m['firstName'] ?? '').toString();
          final last = (m['lastName'] ?? '').toString();
          final fullName = (m['fullName'] ?? '').toString();
          final name =
          (('$first $last').trim().isEmpty ? fullName : '$first $last')
              .trim();
          final hasPastor = (m['roles'] is List) &&
              (m['roles'] as List)
                  .map((e) => e.toString().toLowerCase())
                  .contains('pastor');
          final hasUsher = (m['roles'] is List) &&
              (m['roles'] as List)
                  .map((e) => e.toString().toLowerCase())
                  .contains('usher');
          final hasMedia = (m['roles'] is List) &&
              (m['roles'] as List)
                  .map((e) => e.toString().toLowerCase())
                  .contains('media');

          return ListTile(
            leading: Checkbox(
              value: _selectedMemberIds.contains(id),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedMemberIds.add(id);
                  } else {
                    _selectedMemberIds.remove(id);
                  }
                });
              },
            ),
            title: Text(name.isEmpty ? 'Unnamed member' : name),
            subtitle: Wrap(
              spacing: 6,
              children: [
                if (hasPastor) const Chip(label: Text('Pastor')),
                if (hasUsher) const Chip(label: Text('Usher')),
                if (hasMedia) const Chip(label: Text('Media')),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Admin Setter'),
        // ✅ FIX: attach the TabController here (remove `const` so it can use the field)
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.settings), text: 'Debug & Roles'),
            Tab(icon: Icon(Icons.verified_user), text: 'Grant Permissions'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchUserData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
        controller: _tabController,
        children: [
          // ======== Tab 1: existing controls ========
          Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(
              children: [
                const Text("🛠️ Debug Info",
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 20)),
                const SizedBox(height: 20),
                Text("👤 User ID: ${_userId ?? 'Not logged in'}"),
                Text(
                    "🆔 Linked Member ID: ${_linkedMemberId ?? 'Not linked'}"),
                if (_linkedMemberName != null) ...[
                  const SizedBox(height: 8),
                  Text("📛 Member Name: $_linkedMemberName"),
                  Text(_isLeader ? "⭐ Leader" : "👤 Regular Member"),
                ],
                const Divider(height: 30),

                const Text("🔐 User Roles",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_rolesFromUsers.isEmpty
                    ? 'No roles'
                    : _rolesFromUsers.join(', ')),

                const SizedBox(height: 10),
                const Text("🏆 User Leadership Ministries",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_leadershipMinistriesFromUsers.isEmpty
                    ? 'None'
                    : _leadershipMinistriesFromUsers.join(', ')),

                const Divider(height: 30),

                const Text("🔐 Member Roles",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_rolesFromMembers.isEmpty
                    ? 'No roles'
                    : _rolesFromMembers.join(', ')),

                const SizedBox(height: 10),
                const Text("🏆 Member Leadership Ministries",
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(_leadershipMinistriesFromMembers.isEmpty
                    ? 'None'
                    : _leadershipMinistriesFromMembers.join(', ')),

                const SizedBox(height: 20),

                ElevatedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text("Sync Leader Role"),
                  onPressed: _syncLeaderRole,
                ),

                const SizedBox(height: 30),
                ElevatedButton.icon(
                  icon: const Icon(Icons.security),
                  label: const Text("Promote Me to Admin"),
                  onPressed: _setAdminRole,
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text("Remove Admin Role"),
                  onPressed: _removeAdminRole,
                  style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text("Link Me to Member by Email"),
                  onPressed: _linkUserToMember,
                ),

                const SizedBox(height: 30),
                const Divider(height: 30),
                const Text(
                  "👤 Pastor Role Manager (Admin)",
                  style:
                  TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search by member name or email...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searching
                        ? const Padding(
                      padding: EdgeInsets.all(10.0),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child:
                        CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                        : (_searchCtrl.text.isNotEmpty
                        ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchResults = []);
                      },
                    )
                        : null),
                    border: const OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => _runSearch(v.trim()),
                ),
                if (_searchError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_searchError,
                      style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 12),
                if (_searchResults.isEmpty &&
                    _searchCtrl.text.isNotEmpty &&
                    !_searching)
                  const Text('No members found.'),
                ..._searchResults.map((m) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        (m.name.isNotEmpty ? m.name[0] : '?')
                            .toUpperCase(),
                      ),
                    ),
                    title: Text(m.name),
                    subtitle:
                    Text(m.email.isEmpty ? 'No email' : m.email),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.roles
                            .map((e) => e.toLowerCase())
                            .contains('pastor'))
                          OutlinedButton.icon(
                            icon: const Icon(Icons.remove),
                            label: const Text('Remove Pastor'),
                            onPressed: () => _setPastorRoleOnMember(m,
                                makePastor: false),
                          )
                        else
                          ElevatedButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Grant Pastor'),
                            onPressed: () => _setPastorRoleOnMember(m,
                                makePastor: true),
                          ),
                      ],
                    ),
                  ),
                )),
              ],
            ),
          ),

          // ======== Tab 2: Grant Permissions (new) ========
          _buildGrantPermissionsTab(),
        ],
      ),
    );
  }
}

// Helper model for pastor search
class _MemberResult {
  final String id;
  final String name;
  final String email;
  final List<String> roles;

  _MemberResult({
    required this.id,
    required this.name,
    required this.email,
    required this.roles,
  });

  _MemberResult copyWith({
    String? id,
    String? name,
    String? email,
    List<String>? roles,
  }) {
    return _MemberResult(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      roles: roles ?? this.roles,
    );
  }
}
