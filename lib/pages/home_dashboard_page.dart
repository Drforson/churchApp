// lib/pages/home_dashboard_page.dart
import 'dart:async';
import 'package:church_management_app/widgets/notificationbell_widget.dart';
import 'package:church_management_app/widgets/rolebadge.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'notification_center_page.dart'; // <-- added

class HomeDashboardPage extends StatefulWidget {
  const HomeDashboardPage({super.key});

  @override
  State<HomeDashboardPage> createState() => _HomeDashboardPageState();
}

class _HomeDashboardPageState extends State<HomeDashboardPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will be returned to the login screen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed != true) return;

    await _auth.signOut();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        centerTitle: true,
        backgroundColor: Colors.blueGrey,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Logout',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
          // ⬇️ make bell tappable and navigate to Notification Center
          NotificationBell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationCenterPage()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<DocumentSnapshot>(
          future: _db.collection('users').doc(uid).get(),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!userSnap.hasData || !userSnap.data!.exists) {
              return const Center(child: Text('User record not found.'));
            }

            final user = (userSnap.data!.data() as Map<String, dynamic>?) ?? {};
            final memberId = user['memberId'] as String?;
            final roles = List<String>.from(user['roles'] ?? const []);
            final userFullName = (user['fullName'] ?? '').toString().trim();

            String effectiveRole = roles.contains('admin')
                ? 'admin'
                : roles.contains('leader')
                ? 'leader'
                : 'member';

            if (memberId == null) {
              final profileProgress = _profileProgress(user, null);
              final name = userFullName.isNotEmpty ? userFullName : 'Member';
              return _ScaffoldBody(
                name: name,
                role: effectiveRole,
                profileProgress: profileProgress,
              );
            }

            return StreamBuilder<DocumentSnapshot>(
              stream: _db.collection('members').doc(memberId).snapshots(),
              builder: (context, memSnap) {
                if (memSnap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final member = memSnap.data?.data() as Map<String, dynamic>?;
                String name = userFullName.isNotEmpty ? userFullName : 'Member';

                if (member != null) {
                  final fn = (member['firstName'] ?? '').toString().trim();
                  final ln = (member['lastName'] ?? '').toString().trim();
                  final n = '$fn $ln'.trim();
                  if (n.isNotEmpty) name = n;

                  // Escalate to 'leader' if not already and member leads any ministry
                  final leadFromMembers =
                  List<String>.from(member['leadershipMinistries'] ?? const []);
                  if (effectiveRole == 'member' && leadFromMembers.isNotEmpty) {
                    effectiveRole = 'leader';
                  }
                }

                final profileProgress = _profileProgress(user, member);
                return _ScaffoldBody(
                  name: name,
                  role: effectiveRole,
                  profileProgress: profileProgress,
                );
              },
            );
          },
        ),
      ),
    );
  }

  double _profileProgress(Map<String, dynamic> user, Map<String, dynamic>? member) {
    int filled = 0;
    const total = 5;

    final fullName = (() {
      final fn = member?['firstName'];
      final ln = member?['lastName'];
      if ((fn != null && '$fn'.trim().isNotEmpty) || (ln != null && '$ln'.trim().isNotEmpty)) {
        return '${fn ?? ''} ${ln ?? ''}'.trim();
      }
      return user['fullName'];
    })();

    if (fullName != null && (fullName as String).trim().isNotEmpty) filled++;
    if ((user['email'] ?? member?['email']) != null) filled++;
    if ((member?['phoneNumber'] ?? user['phoneNumber']) != null) filled++;
    if ((member?['gender'] ?? user['gender']) != null) filled++;
    if ((member?['dateOfBirth'] ?? user['dateOfBirth']) != null) filled++;

    return (filled / total).clamp(0.0, 1.0);
  }
}

/* ---------------- Main Body ---------------- */

class _ScaffoldBody extends StatelessWidget {
  final String name;
  final String role;
  final double profileProgress;

  const _ScaffoldBody({
    required this.name,
    required this.role,
    required this.profileProgress,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {},
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _HeaderCard(name: name, role: role, profileProgress: profileProgress),
          const SizedBox(height: 14),
          const _HomeStatsGrid(),
          const SizedBox(height: 16),
          _NoticeBoardCarousel(),
          const SizedBox(height: 16),
          const _SectionTitle('Quick Links'),
          const SizedBox(height: 8),
          _QuickActions(role: role),
        ],
      ),
    );
  }
}

/* ---------------- Header ---------------- */

class _HeaderCard extends StatelessWidget {
  final String name;
  final String role;
  final double profileProgress;

  const _HeaderCard({required this.name, required this.role, required this.profileProgress});

  @override
  Widget build(BuildContext context) {
    final roleLabel = role[0].toUpperCase() + role.substring(1);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12, offset: const Offset(0, 6))
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFFE8ECF3),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1F2937)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    RoleBadge(role: roleLabel.toLowerCase()),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: profileProgress,
                    backgroundColor: Colors.grey.shade200,
                    color: const Color(0xFF10B981),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Profile ${(profileProgress * 100).toInt()}% complete',
                  style:
                  Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF4B5563)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- Stats ---------------- */

class _HomeStatsGrid extends StatelessWidget {
  const _HomeStatsGrid();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final columns = c.maxWidth >= 720 ? 4 : 3;
      final ratio = columns >= 4 ? 1.2 : 0.72;
      return GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: ratio,
        children: const [
          _StatTile(label: 'My Ministries', icon: Icons.groups_2_rounded, query: _HomeStatQuery.myMinistries),
          _StatTile(label: 'Upcoming', icon: Icons.event_available, query: _HomeStatQuery.upcomingEvents),
          _StatTile(label: 'Birthdays', icon: Icons.cake_outlined, query: _HomeStatQuery.birthdays),
        ],
      );
    });
  }
}

enum _HomeStatQuery { myMinistries, upcomingEvents, birthdays }

class _StatTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final _HomeStatQuery query;

  const _StatTile({required this.label, required this.icon, required this.query});

  Stream<int> _stream() {
    final db = FirebaseFirestore.instance;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    switch (query) {
      case _HomeStatQuery.myMinistries:
        return db.collection('users').doc(uid).snapshots().asyncMap((u) async {
          final data = u.data() ?? {};
          final memberId = data['memberId'];
          if (memberId == null) return 0;
          final mem = await db.collection('members').doc(memberId).get();
          final md = mem.data() ?? {};
          final mins = List<String>.from(md['ministries'] ?? const []);
          return mins.length;
        }).handleError((_) => 0);
      case _HomeStatQuery.upcomingEvents:
        return db
            .collection('events')
            .where('startDate', isGreaterThanOrEqualTo: Timestamp.now())
            .limit(500)
            .snapshots()
            .map((s) => s.size);
      case _HomeStatQuery.birthdays:
        return db.collection('members').snapshots().map((s) {
          final now = DateTime.now();
          final week = List.generate(7, (i) => DateTime(now.year, now.month, now.day + i));
          int count = 0;
          for (final d in s.docs) {
            final m = d.data() as Map<String, dynamic>;
            final ts = m['dateOfBirth'];
            if (ts is! Timestamp) continue;
            final dob = ts.toDate();
            final has = week.any((w) => w.month == dob.month && w.day == dob.day);
            if (has) count++;
          }
          return count;
        }).handleError((_) => 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _stream(),
      builder: (context, snap) {
        final count = snap.data ?? 0;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 5))
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
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
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
        );
      },
    );
  }
}

/* ---------------- Noticeboard Carousel ---------------- */

class _NoticeBoardCarousel extends StatefulWidget {
  @override
  State<_NoticeBoardCarousel> createState() => _NoticeBoardCarouselState();
}

class _NoticeBoardCarouselState extends State<_NoticeBoardCarousel> {
  final _controller = PageController(viewportFraction: 0.92);
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_controller.hasClients) return;
      _page++;
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

            if (combined.isEmpty) {
              return _EmptyNotice();
            }

            return Container(
              height: 172,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white70),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 6))
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
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFF4B5563)),
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
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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

/* ---------------- Quick Actions ---------------- */

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final String role;
  const _QuickActions({required this.role});

  @override
  Widget build(BuildContext context) {
    final items = <_ActionItem>[
      _ActionItem('Ministries', Icons.group, '/view-ministry'),
      _ActionItem('Giving', Icons.card_giftcard, '/giving'),
      _ActionItem('Events', Icons.event, '/events'),
      _ActionItem('Profile', Icons.person, '/profile'),
      _ActionItem('My Requests', Icons.volunteer_activism_rounded, '/forms'),
      if (role == 'admin' || role == 'leader')
        _ActionItem('Admin/Leader Tools', Icons.admin_panel_settings, '/testadmin'),
    ];

    return LayoutBuilder(builder: (context, c) {
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
    });
  }
}

class _ActionItem {
  final String label;
  final IconData icon;
  final String route;
  _ActionItem(this.label, this.icon, this.route);
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
            BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 6))
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
