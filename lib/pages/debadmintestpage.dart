import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:async';

class DebugAdminSetterPage extends StatefulWidget {
  const DebugAdminSetterPage({super.key});

  @override
  State<DebugAdminSetterPage> createState() => _DebugAdminSetterPageState();
}

class _DebugAdminSetterPageState extends State<DebugAdminSetterPage> {
  String? _userId;
  String? _linkedMemberId;
  String? _linkedMemberName;
  bool _isLeader = false;
  List<String> _rolesFromUsers = [];
  List<String> _rolesFromMembers = [];
  List<String> _leadershipMinistriesFromUsers = [];
  List<String> _leadershipMinistriesFromMembers = [];
  bool _loading = false;

  // ===== NEW: Pastor role manager state =====
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String _searchError = '';
  List<_MemberResult> _searchResults = [];

  bool get _isAdminNow =>
      _rolesFromUsers.contains('admin') || _rolesFromMembers.contains('admin');

  @override
  void initState() {
    super.initState();
    _fetchUserData();

    // Debounce search
    _searchCtrl.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        _runSearch(_searchCtrl.text.trim());
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchUserData() async {
    setState(() => _loading = true);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('[DEBUG] No user is logged in.');
      setState(() => _loading = false);
      return;
    }

    final userId = user.uid;
    debugPrint('[DEBUG] Fetching user data for UID: $userId');

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final userData = userDoc.data();

    if (userData != null) {
      debugPrint('[DEBUG] User document data: $userData');

      final memberId = userData['memberId'];
      final rolesFromUsers = List<String>.from(userData['roles'] ?? []);
      final leadershipMinistriesFromUsers = List<String>.from(userData['leadershipMinistries'] ?? []);

      debugPrint('[DEBUG] Roles from User Document: $rolesFromUsers');
      debugPrint('[DEBUG] Leadership Ministries from User Document: $leadershipMinistriesFromUsers');

      List<String> rolesFromMembers = [];
      List<String> leadershipMinistriesFromMembers = [];
      String? fullName;
      bool isLeader = false;

      bool updated = false;

      if (memberId != null) {
        debugPrint('[DEBUG] Linked Member ID: $memberId');

        final memberDoc = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
        if (memberDoc.exists) {
          final memberData = memberDoc.data();
          debugPrint('[DEBUG] Member document data: $memberData');

          rolesFromMembers = List<String>.from(memberData?['roles'] ?? []);
          leadershipMinistriesFromMembers = List<String>.from(memberData?['leadershipMinistries'] ?? []);
          fullName = "${memberData?['firstName'] ?? ''} ${memberData?['lastName'] ?? ''}".trim();
          isLeader = leadershipMinistriesFromMembers.isNotEmpty;

          debugPrint('[DEBUG] Roles from Member Document: $rolesFromMembers');
          debugPrint('[DEBUG] Leadership Ministries from Member Document: $leadershipMinistriesFromMembers');

          // Merge roles and leadershipMinistries (users doc stays the truth source we can write)
          final mergedRoles = {...rolesFromUsers, ...rolesFromMembers}.toList();
          final mergedLeadershipMinistries = {...leadershipMinistriesFromUsers, ...leadershipMinistriesFromMembers}.toList();

          debugPrint('[DEBUG] Merged Roles: $mergedRoles');
          debugPrint('[DEBUG] Merged Leadership Ministries: $mergedLeadershipMinistries');

          if (mergedRoles.length != rolesFromUsers.length ||
              mergedLeadershipMinistries.length != leadershipMinistriesFromUsers.length) {
            debugPrint('[DEBUG] Changes detected, updating user document.');
            await FirebaseFirestore.instance.collection('users').doc(userId).set({
              'roles': mergedRoles,
              'leadershipMinistries': mergedLeadershipMinistries,
            }, SetOptions(merge: true));

            updated = true;
          } else {
            debugPrint('[DEBUG] No changes detected, skipping Firestore update.');
          }
        } else {
          debugPrint('[DEBUG] Member document does not exist.');
        }
      } else {
        debugPrint('[DEBUG] No member linked to user.');
      }

      setState(() {
        _userId = userId;
        _linkedMemberId = memberId;
        _rolesFromUsers = rolesFromUsers;
        _rolesFromMembers = rolesFromMembers;
        _leadershipMinistriesFromUsers = leadershipMinistriesFromUsers;
        _leadershipMinistriesFromMembers = leadershipMinistriesFromMembers;
        _linkedMemberName = (fullName == null || fullName.isEmpty) ? null : fullName;
        _isLeader = isLeader || leadershipMinistriesFromUsers.isNotEmpty;
        _loading = false;
      });

      if (updated && mounted) {
        debugPrint('[DEBUG] Showing Snackbar: Roles and Leadership Ministries updated.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Roles and Leadership Ministries updated successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }

      // auto-sync leader role/status into users doc
      await _syncLeaderRole();
    } else {
      debugPrint('[DEBUG] User document does not exist for UID: $userId');
      setState(() => _loading = false);
    }
  }

  // Discover leadership ministries from ministries/* where leaderIds contains the current uid
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

  // Ensure users/{uid} reflects true leader status; optionally mirror to members/{id} via CF
  Future<void> _syncLeaderRole() async {
    if (_userId == null) return;

    try {
      final userMin = _leadershipMinistriesFromUsers.toSet();
      final memberMin = _leadershipMinistriesFromMembers.toSet();
      final discovered = await _discoverLeadershipFromMinistriesCollection(_userId!);

      final unified = <String>{...userMin, ...memberMin, ...discovered};

      debugPrint('[SYNC] Unified leadership ministries for user $_userId: $unified');

      if (unified.isEmpty) {
        return;
      }

      await FirebaseFirestore.instance.collection('users').doc(_userId).set({
        'roles': FieldValue.arrayUnion(['leader']),
        'leadershipMinistries': unified.toList(),
      }, SetOptions(merge: true));

      setState(() {
        if (!_rolesFromUsers.contains('leader')) _rolesFromUsers = [..._rolesFromUsers, 'leader'];
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
          debugPrint('[SYNC] ensureMemberLeaderRole called for memberId=$_linkedMemberId');
        } on FirebaseFunctionsException catch (e) {
          debugPrint('[SYNC] ensureMemberLeaderRole failed: ${e.code} ${e.message}');
        } catch (e) {
          debugPrint('[SYNC] ensureMemberLeaderRole error: $e');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Leader role synced')),
        );
      }
    } catch (e) {
      debugPrint('[SYNC] Error during sync: $e');
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
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Promote failed: ${e.code} ${e.message ?? ''}')),
      );
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
    final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final memberId = userDoc.data()?['memberId'];

    await FirebaseFirestore.instance.collection('users').doc(userId).update({
      'roles': FieldValue.arrayRemove(['admin']),
    });

    if (memberId != null) {
      await FirebaseFirestore.instance.collection('members').doc(memberId).update({
        'roles': FieldValue.arrayRemove(['admin']),
      });
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
      final fullName = "${memberData['firstName'] ?? ''} ${memberData['lastName'] ?? ''}".trim();
      final leadershipMinistries = List<String>.from(memberData['leadershipMinistries'] ?? []);
      final isLeader = leadershipMinistries.isNotEmpty;

      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'memberId': memberId,
      });

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

  Widget _buildQuickLinkButton(BuildContext context, IconData icon, String label, String route) {
    return Column(
      children: [
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, route),
          child: CircleAvatar(
            radius: 26,
            backgroundColor: Colors.deepPurple,
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ===== NEW: Search and Pastor role helpers =====

  Future<void> _runSearch(String query) async {
    if (!_isAdminNow) return; // safety: only admins can search/manage
    setState(() {
      _searching = true;
      _searchError = '';
      _searchResults = [];
    });

    try {
      final col = FirebaseFirestore.instance.collection('members');

      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = [];

      if (query.isEmpty) {
        // Show nothing on empty query
        docs = [];
      } else if (query.contains('@')) {
        // email exact match
        final qs = await col.where('email', isEqualTo: query).limit(10).get();
        docs = qs.docs;
      } else {
        // Try prefix search on fullNameLower
        final qLower = query.toLowerCase();
        try {
          final qs = await col
              .orderBy('fullNameLower')
              .startAt([qLower])
              .endAt(['$qLower\uf8ff'])
              .limit(20)
              .get();
          docs = qs.docs;
        } catch (e) {
          // Fallback: fetch small set and filter client-side
          final qs = await col.limit(50).get();
          docs = qs.docs.where((d) {
            final data = d.data();
            final first = (data['firstName'] ?? '').toString().toLowerCase();
            final last = (data['lastName'] ?? '').toString().toLowerCase();
            final full = ('$first $last').trim();
            return first.contains(qLower) || last.contains(qLower) || full.contains(qLower);
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
  Future<void> _setPastorRoleOnMember(_MemberResult m, {required bool makePastor}) async {
    if (!_isAdminNow) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only admins can modify roles.')),
      );
      return;
    }

    try {
      // 1) Try Cloud Function (preferred: centralized auth + audit)
      bool cfWorked = false;
      try {
        final callable = FirebaseFunctions.instance.httpsCallable(
          'setMemberPastorRole',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
        );
        await callable.call(<String, dynamic>{'memberId': m.id, 'makePastor': makePastor});
        cfWorked = true;
      } on FirebaseFunctionsException catch (e) {
        debugPrint('[PastorRole] CF failed: ${e.code} ${e.message} — trying client write.');
      }

      // 2) Client-side fallback if CF not available (make sure Firestore rules allow admin)
      if (!cfWorked) {
        await FirebaseFirestore.instance.collection('members').doc(m.id).update({
          'roles': makePastor
              ? FieldValue.arrayUnion(['pastor'])
              : FieldValue.arrayRemove(['pastor']),
          // Optional legacy boolean your app might read:
          'isPastor': makePastor,
        });
      }

      // 3) Keep users/{uid} in sync if that member is linked to a user
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

      // 4) Update the local list UI
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
        SnackBar(content: Text(makePastor ? '✅ Pastor role granted' : '✅ Pastor role removed')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Update failed: $e')),
      );
    }
  }


  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Admin Setter'),
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
          : Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Text("🛠️ Debug Info",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
            const SizedBox(height: 20),
            Text("👤 User ID: ${_userId ?? 'Not logged in'}"),
            Text("🆔 Linked Member ID: ${_linkedMemberId ?? 'Not linked'}"),
            if (_linkedMemberName != null) ...[
              const SizedBox(height: 8),
              Text("📛 Member Name: $_linkedMemberName"),
              Text(_isLeader ? "⭐ Leader" : "👤 Regular Member"),
            ],
            const Divider(height: 30),

            const Text("🔐 User Roles", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_rolesFromUsers.isEmpty ? 'No roles' : _rolesFromUsers.join(', ')),

            const SizedBox(height: 10),
            const Text("🏆 User Leadership Ministries",
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_leadershipMinistriesFromUsers.isEmpty
                ? 'None'
                : _leadershipMinistriesFromUsers.join(', ')),

            const Divider(height: 30),

            const Text("🔐 Member Roles", style: TextStyle(fontWeight: FontWeight.bold)),
            Text(_rolesFromMembers.isEmpty ? 'No roles' : _rolesFromMembers.join(', ')),

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
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.link),
              label: const Text("Link Me to Member by Email"),
              onPressed: _linkUserToMember,
            ),
            const SizedBox(height: 20),

            const Divider(),
            _buildQuickLinkButton(context, Icons.group, "Ministries", "/view-ministry"),

            // ===== NEW: Admin-only Pastor Role Manager =====
            if (_isAdminNow) ...[
              const SizedBox(height: 30),
              const Divider(height: 30),
              const Text(
                "👤 Pastor Role Manager (Admin)",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
                      child: CircularProgressIndicator(strokeWidth: 2),
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
                Text(_searchError, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 12),
              if (_searchResults.isEmpty && _searchCtrl.text.isNotEmpty && !_searching)
                const Text('No members found.'),
              ..._searchResults.map((m) => Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(
                      (m.name.isNotEmpty ? m.name[0] : '?').toUpperCase(),
                    ),
                  ),
                  title: Text(m.name),
                  subtitle: Text(m.email.isEmpty ? 'No email' : m.email),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (m.roles.contains('pastor'))
                        OutlinedButton.icon(
                          icon: const Icon(Icons.remove),
                          label: const Text('Remove Pastor'),
                          onPressed: () => _setPastorRoleOnMember(m, makePastor: false),
                        )
                      else
                        ElevatedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Grant Pastor'),
                          onPressed: () => _setPastorRoleOnMember(m, makePastor: true),
                        ),
                    ],
                  ),
                ),
              )),
            ],
          ],
        ),
      ),
    );
  }
}

// ===== Helper model for search results =====
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
