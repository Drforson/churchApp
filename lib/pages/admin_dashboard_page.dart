// lib/pages/admin_dashboard_page.dart
import 'dart:async';
import 'package:church_management_app/widgets/notificationbell_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';

import 'ministries_details_page.dart';
import 'notification_center_page.dart'; // <-- added

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');

  bool _isAdmin = false;
  bool _isLeader = false;
  bool _isPastor = false; // gate for “My Follow-Up”
  Set<String> _leadershipMinistries = {};
  String? _displayName; // show real user name
  int _managedMembersCount = 0;
  int _pendingJoinRequestsCount = 0;

  @override
  void initState() {
    super.initState();
    _primeRole();
  }

  /// Pull roles + best-effort name from users + members
  /// Pull roles + best-effort name from users + members + auth claims
  Future<void> _primeRole() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    // 1) Read auth claims (set by your Functions via setCustomUserClaims)
    final claims = await _auth.currentUser!.getIdTokenResult(true);
    final tok = claims.claims ?? const {};

    bool claimAdmin = (tok['admin'] == true) || (tok['isAdmin'] == true);
    bool claimPastor = (tok['pastor'] == true) || (tok['isPastor'] == true);
    bool claimLeader = (tok['leader'] == true) || (tok['isLeader'] == true);

    // 2) Read users/{uid}
    final userSnap = await _db.collection('users').doc(uid).get();
    final u = userSnap.data() ?? {};

    // Single role (preferred)
    final singleRole = (u['role'] as String?)?.trim().toLowerCase();

    // Legacy roles array
    final rolesArr = (u['roles'] is List)
        ? List<String>.from(
            (u['roles'] as List).map((e) => e.toString().toLowerCase()))
        : const <String>[];

    // Leadership (user doc)
    final userLeadMins = (u['leadershipMinistries'] is List)
        ? List<String>.from(
            (u['leadershipMinistries'] as List).map((e) => e.toString()))
        : const <String>[];

    String? name = (u['displayName'] ?? u['name'])?.toString();
    final memberId = u['memberId'] as String?;

    // 3) Derive admin/leader/pastor from users doc (single + array + flags + claims)
    final userIsAdmin = (u['admin'] == true) || (u['isAdmin'] == true);
    final userIsPastor = (u['pastor'] == true) || (u['isPastor'] == true);
    final userIsLeader = (u['leader'] == true) || (u['isLeader'] == true);

    bool isAdmin = claimAdmin ||
        userIsAdmin ||
        singleRole == 'admin' ||
        rolesArr.contains('admin');
    bool isLeader = claimLeader ||
        userIsLeader ||
        singleRole == 'leader' ||
        rolesArr.contains('leader') ||
        userLeadMins.isNotEmpty;
    bool isPastor = claimPastor ||
        userIsPastor ||
        singleRole == 'pastor' ||
        rolesArr.contains('pastor');

    // 4) Merge with members/{memberId} (roles, flags, name, leadership)
    final mins = <String>{...userLeadMins};
    if (memberId != null && memberId.isNotEmpty) {
      Map<String, dynamic> md = const <String, dynamic>{};
      try {
        final mSnap = await _db.collection('members').doc(memberId).get();
        md = mSnap.data() ?? {};
      } on FirebaseException catch (e) {
        debugPrint('[AdminDashboard] members/$memberId read failed: ${e.code}');
      }

      // Leadership from member doc
      final memberLeadMins = (md['leadershipMinistries'] is List)
          ? List<String>.from(
              (md['leadershipMinistries'] as List).map((e) => e.toString()))
          : const <String>[];
      mins.addAll(memberLeadMins);

      // Roles from member doc
      final memberRoles = (md['roles'] is List)
          ? List<String>.from(
              (md['roles'] as List).map((e) => e.toString().toLowerCase()))
          : const <String>[];

      final memberIsPastorFlag = (md['isPastor'] == true);

      // Upgrade derived booleans if member doc indicates so
      isAdmin = isAdmin || memberRoles.contains('admin');
      isLeader = isLeader ||
          memberRoles.contains('leader') ||
          memberLeadMins.isNotEmpty;
      isPastor =
          isPastor || memberIsPastorFlag || memberRoles.contains('pastor');

      // Name fallback from members
      if (name == null || name.trim().isEmpty) {
        final first = (md['firstName'] ?? '').toString();
        final last = (md['lastName'] ?? '').toString();
        final full = ('$first $last').trim();
        name = full.isNotEmpty ? full : (md['fullName'] ?? '').toString();
      }
    }

    // 5) Final fallback for name
    name ??= _auth.currentUser?.displayName ??
        _auth.currentUser?.email?.split('@').first ??
        'Member';

    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _isLeader = isLeader;
      _isPastor = isPastor;
      _leadershipMinistries = mins;
      _displayName = name!;
    });
    await _loadManagedStats(canManage: isAdmin || isLeader || isPastor);
  }

  Future<void> _loadManagedStats({required bool canManage}) async {
    if (!canManage) {
      if (!mounted) return;
      setState(() {
        _managedMembersCount = 0;
        _pendingJoinRequestsCount = 0;
      });
      return;
    }

    try {
      final res =
          await _functions.httpsCallable('getAdminDashboardStats').call();
      final data = (res.data is Map)
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};
      final members = (data['membersCount'] is num)
          ? (data['membersCount'] as num).toInt()
          : 0;
      final pending = (data['pendingJoinRequestsCount'] is num)
          ? (data['pendingJoinRequestsCount'] as num).toInt()
          : 0;

      if (!mounted) return;
      setState(() {
        _managedMembersCount = members;
        _pendingJoinRequestsCount = pending;
      });
    } catch (e) {
      debugPrint('[AdminDashboard] stats load failed: $e');
    }
  }

  Future<void> _logout(BuildContext context) async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _openPendingJoinRequestsTarget() async {
    String? targetMinistryName;
    String? targetMinistryId;

    if (_leadershipMinistries.isNotEmpty) {
      targetMinistryName = _leadershipMinistries.first;
      try {
        final q = await _db
            .collection('ministries')
            .where('name', isEqualTo: targetMinistryName)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          targetMinistryId = q.docs.first.id;
        }
      } catch (_) {}
    }

    if (targetMinistryId == null) {
      try {
        final q =
            await _db.collection('ministries').orderBy('name').limit(1).get();
        if (q.docs.isNotEmpty) {
          targetMinistryId = q.docs.first.id;
          targetMinistryName ??=
              (q.docs.first.data()['name'] ?? '').toString().trim();
        }
      } catch (_) {}
    }

    if (!mounted) return;
    if (targetMinistryId != null &&
        targetMinistryName != null &&
        targetMinistryName.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MinistryDetailsPage(
            ministryId: targetMinistryId!,
            ministryName: targetMinistryName!,
          ),
        ),
      );
      return;
    }

    Navigator.pushNamed(context, '/view-ministry');
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _isAdmin || _isLeader || _isPastor;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_isAdmin
            ? 'Admin Dashboard'
            : _isLeader
                ? 'Leader Dashboard'
                : 'Dashboard'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _primeRole,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
          // ⬇️ Make the bell tappable to open Notification Center
          NotificationBell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationCenterPage()),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF7F8FA), Color(0xFFEEF1F5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => _primeRole(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _HeaderCard(
                  isAdmin: _isAdmin,
                  isLeader: _isLeader,
                  ministries: _leadershipMinistries,
                  displayName: _displayName ?? 'Member',
                ),
                const SizedBox(height: 14),
                _StatsGrid(
                  canManage: canManage,
                  managedMembersCount: _managedMembersCount,
                  pendingJoinRequestsCount: _pendingJoinRequestsCount,
                  onOpenPendingJoins: _openPendingJoinRequestsTarget,
                ),
                const SizedBox(height: 18),
                _NoticeBoardCarousel(),
                const SizedBox(height: 18),
                const _SectionTitle('Quick Actions'),
                const SizedBox(height: 8),
                _ActionsGrid(
                  canManage: canManage,
                  isPastor: _isPastor, // show “My Follow-Up”
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* -------------------- Header -------------------- */

class _HeaderCard extends StatelessWidget {
  final bool isAdmin;
  final bool isLeader;
  final Set<String> ministries;
  final String displayName;

  const _HeaderCard({
    required this.isAdmin,
    required this.isLeader,
    required this.ministries,
    required this.displayName,
  });

  @override
  Widget build(BuildContext context) {
    final roleLabel = isAdmin
        ? 'Admin'
        : isLeader
            ? 'Leader'
            : 'Member';

    final subtitle = isAdmin
        ? 'Role: Admin • Manage church-wide content and settings'
        : isLeader
            ? (ministries.isEmpty
                ? 'Role: Leader'
                : 'Role: Leader • Leader of: ${ministries.take(3).join(", ")}${ministries.length > 3 ? " +" : ""}')
            : 'Role: Member • Welcome back';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 12,
              offset: const Offset(0, 6))
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFFE8ECF3),
            child: Icon(isAdmin ? Icons.admin_panel_settings : Icons.verified,
                color: Colors.indigo, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, $displayName',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: const Color(0xFF4B5563)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8ECF3),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              roleLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1F2937),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/* -------------------- Stats (RESPONSIVE, OVERFLOW-SAFE) -------------------- */

class _StatsGrid extends StatelessWidget {
  final bool canManage;
  final int managedMembersCount;
  final int pendingJoinRequestsCount;
  final VoidCallback onOpenPendingJoins;
  const _StatsGrid({
    required this.canManage,
    required this.managedMembersCount,
    required this.pendingJoinRequestsCount,
    required this.onOpenPendingJoins,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 720
            ? 4
            : constraints.maxWidth >= 520
                ? 3
                : 3;

        final ratio = crossAxisCount >= 4 ? 1.0 : 0.65;
        final tiles = <Widget>[
          const _StatTile(
              label: 'Ministries',
              icon: Icons.church,
              query: _StatQuery.ministries,
              routeName: '/view-ministry'),
          const _StatTile(
              label: 'Upcoming',
              icon: Icons.event_available,
              query: _StatQuery.upcomingEvents,
              routeName: '/events'),
          if (canManage)
            _CountTile(
              label: 'Members',
              icon: Icons.groups,
              count: managedMembersCount,
              onTap: () => Navigator.pushNamed(context, '/view-members'),
            ),
          if (canManage)
            _CountTile(
              label: 'Pending Joins',
              icon: Icons.group_add,
              count: pendingJoinRequestsCount,
              onTap: onOpenPendingJoins,
            ),
        ];

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: ratio,
          children: tiles,
        );
      },
    );
  }
}

enum _StatQuery { ministries, upcomingEvents }

class _StatTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final _StatQuery query;
  final String? routeName;

  const _StatTile(
      {required this.label,
      required this.icon,
      required this.query,
      this.routeName});

  Stream<int> _stream() {
    final db = FirebaseFirestore.instance;
    switch (query) {
      case _StatQuery.ministries:
        return db
            .collection('ministries')
            .limit(500)
            .snapshots()
            .map((s) => s.size);
      case _StatQuery.upcomingEvents:
        return db
            .collection('events')
            .where('startDate', isGreaterThanOrEqualTo: Timestamp.now())
            .limit(500)
            .snapshots()
            .map((s) => s.size);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _stream(),
      builder: (context, snap) {
        final count = snap.data ?? 0;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: routeName == null
                ? null
                : () => Navigator.pushNamed(context, routeName!),
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 5))
                ],
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                children: [
                  SizedBox(
                    height: 36,
                    child: Center(
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: const Color(0xFFE8ECF3),
                        child: Icon(icon, color: Colors.indigo),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$count',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                                color: const Color(0xFF1F2937),
                              ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 22,
                    child: Center(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF4B5563),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CountTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final VoidCallback? onTap;

  const _CountTile({
    required this.label,
    required this.icon,
    required this.count,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 5)),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            children: [
              SizedBox(
                height: 36,
                child: Center(
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFFE8ECF3),
                    child: Icon(icon, color: Colors.indigo),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '$count',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                                color: const Color(0xFF1F2937),
                              ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 22,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF4B5563),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* -------------------- Noticeboard Carousel -------------------- */

class _NoticeBoardCarousel extends StatefulWidget {
  @override
  State<_NoticeBoardCarousel> createState() => _NoticeBoardCarouselState();
}

class _NoticeBoardCarouselState extends State<_NoticeBoardCarousel> {
  final _controller = PageController(viewportFraction: 0.92);
  int _page = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_controller.hasClients) return;
      _page = (_page + 1);
      _controller.animateToPage(
        _page,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final now = Timestamp.now();

    return StreamBuilder<QuerySnapshot>(
      stream: db
          .collection('events')
          .where('startDate', isGreaterThanOrEqualTo: now)
          .orderBy('startDate')
          .limit(5)
          .snapshots(),
      builder: (context, eventsSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: db
              .collection('announcements')
              .orderBy('createdAt', descending: true)
              .limit(5)
              .snapshots(),
          builder: (context, annSnap) {
            final events = eventsSnap.data?.docs ?? const [];
            final anns = annSnap.data?.docs ?? const [];
            final combined = [...events, ...anns];

            if (combined.isEmpty) return _EmptyNotice();

            return Container(
              height: 172,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white70),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 6))
                ],
              ),
              child: PageView.builder(
                controller: _controller,
                itemCount: combined.length,
                itemBuilder: (context, i) {
                  final doc = combined[i];
                  final data = doc.data() as Map<String, dynamic>;
                  final isEvent = data.containsKey('startDate');
                  return _NoticeCard(isEvent: isEvent, data: data);
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptyNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 110,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white70),
      ),
      child: Text(
        'No upcoming events or announcements',
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: const Color(0xFF4B5563)),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final bool isEvent;
  final Map<String, dynamic> data;

  const _NoticeCard({required this.isEvent, required this.data});

  @override
  Widget build(BuildContext context) {
    final title = (data['title'] ?? 'Untitled').toString();

    String subtitle;
    if (isEvent) {
      final dt = (data['startDate'] as Timestamp?)?.toDate();
      if (dt == null) {
        subtitle = 'Unknown date';
      } else {
        final date = DateFormat.yMMMd().format(dt);
        final time = TimeOfDay.fromDateTime(dt).format(context);
        subtitle = '$date • $time';
      }
    } else {
      subtitle = (data['body'] ?? 'No content').toString();
    }

    final icon = isEvent ? Icons.event : Icons.campaign;
    final color = isEvent ? Colors.indigo : Colors.orange;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/* -------------------- Actions -------------------- */

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _ActionsGrid extends StatelessWidget {
  final bool canManage;
  final bool isPastor;
  const _ActionsGrid({required this.canManage, required this.isPastor});

  @override
  Widget build(BuildContext context) {
    final items = <_ActionItem>[
      _ActionItem('Profile', Icons.person, '/profile'),
      _ActionItem('Upload Sermons & Events', Icons.upload, '/admin-upload'),
      _ActionItem(
          'Register Member/Visitor', Icons.how_to_reg, '/register-member'),
      _ActionItem('View Members', Icons.group, '/view-members'),
      _ActionItem('Manage Ministries', Icons.group_work, '/view-ministry'),
      _ActionItem('Post Announcements', Icons.campaign, '/post-announcements'),
      _ActionItem('Events', Icons.event, '/events'),
      _ActionItem('Upload Database', Icons.table_view, '/uploadExcel'),
      _ActionItem(
          'Attendance Check-In', Icons.check_circle_outline, '/attendance'),
      _ActionItem(
          'Attendance Setup', Icons.how_to_reg, '/attendance-setup'),
      _ActionItem('My Requests', Icons.volunteer_activism_rounded, '/forms'),
      _ActionItem('Sunday Follow-Up', Icons.person_off, '/follow-up'),
      _ActionItem('Send Feedback', Icons.feedback_outlined, '/feedback'),
      // FeedbackQuickButton(padding: EdgeInsets.only(left: 8)),
      //  if (role == 'admin' || role == 'leader')
      // _ActionItem('Admin/Leader Tools', Icons.admin_panel_settings, '/testadmin'),

      if (isPastor)
        _ActionItem('My Follow-Up', Icons.assignment_ind, '/my-follow-up'),
      _ActionItem(
          'Admin/Leader Tools', Icons.admin_panel_settings, '/testadmin',
          requireManage: true),
    ].where((i) => !i.requireManage || canManage).toList();

    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 720 ? 4 : 2;
        final aspect = columns == 4 ? 1.25 : 0.88;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: aspect,
          ),
          itemBuilder: (context, i) => _ActionCard(item: items[i]),
        );
      },
    );
  }
}

class _ActionItem {
  final String label;
  final IconData icon;
  final String route;
  final bool requireManage;

  _ActionItem(this.label, this.icon, this.route, {this.requireManage = false});
}

class _ActionCard extends StatelessWidget {
  final _ActionItem item;
  const _ActionCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, item.route),
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 6))
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              SizedBox(
                height: 42,
                child: Center(
                  child: CircleAvatar(
                    radius: 21,
                    backgroundColor: const Color(0xFFE8ECF3),
                    child: Icon(item.icon, color: Colors.indigo),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      item.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF1F2937),
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
