import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class ViewMembersPage extends StatefulWidget {
  const ViewMembersPage({super.key});

  @override
  State<ViewMembersPage> createState() => _ViewMembersPageState();
}

class _ViewMembersPageState extends State<ViewMembersPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _viewMode = 'list';
  String _searchQuery = '';
  late Future<QuerySnapshot> _membersFuture;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west2');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _viewMode = _tabController.index == 4 ? 'chart' : 'list';
        });
      }
    });
    _membersFuture = _loadMembers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _genderBucket(dynamic raw) {
    final g = raw?.toString().toLowerCase().trim() ?? '';
    if (g.isEmpty) return 'other';
    if (g.startsWith('f') || g.contains('female') || g.contains('woman') || g.contains('girl')) {
      return 'female';
    }
    if (g.startsWith('m') || g.contains('male') || g.contains('man') || g.contains('boy')) {
      return 'male';
    }
    return 'other';
  }

  Widget _genderAvatar(Map<String, dynamic> member, {double radius = 20}) {
    final bucket = _genderBucket(member['gender']);
    if (bucket == 'female') {
      return CircleAvatar(
        radius: radius,
        backgroundImage: const AssetImage('assets/images/female_avatar.png'),
      );
    }
    if (bucket == 'male') {
      return CircleAvatar(
        radius: radius,
        backgroundImage: const AssetImage('assets/images/male_avatar.png'),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey.shade200,
      child: Icon(Icons.person, color: Colors.grey.shade700, size: radius),
    );
  }

  Future<void> _ensureRoleSync() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await _functions.httpsCallable('ensureUserDoc').call();
    } catch (_) {}
    try {
      await _functions.httpsCallable('syncUserRoleFromMemberOnLogin').call();
      await user.getIdToken(true);
    } catch (_) {}
  }

  Future<QuerySnapshot> _loadMembers() async {
    await _ensureRoleSync();
    return FirebaseFirestore.instance.collection('members').get();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('View Members'),
        actions: [
          if (_tabController.index != 4)
            IconButton(
              icon: Icon(_viewMode == 'list' ? Icons.grid_view : Icons.list),
              onPressed: () => setState(() => _viewMode = _viewMode == 'list' ? 'grid' : 'list'),
            )
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: 'All Members'),
            Tab(text: 'By Ministry'),
            Tab(text: 'Birthdays'),
            Tab(text: 'Inactive'),
            Tab(text: 'Demographics'),
            Tab(text: 'Newly Registered'),
          ],
        ),
      ),
      body: FutureBuilder<QuerySnapshot>(
        future: _membersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Error: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _membersFuture = _loadMembers();
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final currentMembers = snapshot.data?.docs
              .map((e) => e.data() as Map<String, dynamic>)
              .toList() ??
              [];

          return TabBarView(
            controller: _tabController,
            children: [
              _buildMemberList(currentMembers),
              _buildMinistryList(currentMembers),
              _buildBirthdayList(_filterBirthdays(currentMembers)),
              _buildMemberList(_filterInactive(currentMembers)),
              _buildGenderPieChart(currentMembers),
              _buildMemberList(_filterNewMembers(currentMembers)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMemberList(List<Map<String, dynamic>> members) {
    List<Map<String, dynamic>> filtered = members.where((m) {
      final name = '${m['firstName'] ?? ''} ${m['lastName'] ?? ''}';
      return name.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    filtered.sort((a, b) => ('${a['firstName'] ?? ''}${a['lastName'] ?? ''}')
        .compareTo('${b['firstName'] ?? ''}${b['lastName'] ?? ''}'));

    if (_viewMode == 'grid') {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: filtered.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.8,
        ),
        itemBuilder: (context, index) {
          final member = filtered[index];
          return GestureDetector(
            onTap: () => _openMemberDetail(member),
            child: Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _genderAvatar(member),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('${member['firstName']} ${member['lastName']}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    )
                  ],
                ),
              ),
            ),
          );
        },
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Total Members: ${filtered.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search members...',
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final member = filtered[index];
                return ListTile(
                  leading: _genderAvatar(member),
                  title: Text('${member['firstName']} ${member['lastName']}'),
                  onTap: () => _openMemberDetail(member),
                );
              },
            ),
          ),
        ],
      );
    }
  }

  /*void _openMemberDetail(Map<String, dynamic> member) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${member['firstName'] ?? 'Unnamed'} ${member['lastName'] ?? ''}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: member.entries.map((entry) {
              final key = entry.key;
              final value = entry.value;

              if (value is Timestamp) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text(
                    '${_beautifyKey(key)}: ${DateFormat('yMMMd, h:mm a').format(value.toDate())}',
                    style: const TextStyle(fontSize: 14),
                  ),
                );
              }

              if (value is List) {
                final listString = value.map((e) => e.toString()).join(', ');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text(
                    '${_beautifyKey(key)}: $listString',
                    style: const TextStyle(fontSize: 14),
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Text(
                  '${_beautifyKey(key)}: $value',
                  style: const TextStyle(fontSize: 14),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }*/void _openMemberDetail(Map<String, dynamic> member) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text('${member['firstName'] ?? 'Member'} ${member['lastName'] ?? ''}'),
          ),
          body: SingleChildScrollView(
            child: Column(
              children: [
                // Header with avatar and name
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  color: Colors.teal.shade100,
                  child: Column(
                    children: [
                      _genderAvatar(member, radius: 40),
                      const SizedBox(height: 12),
                      Text(
                        '${member['firstName'] ?? ''} ${member['lastName'] ?? ''}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      if (member['role'] != null)
                        Text(
                          member['role'],
                          style: const TextStyle(color: Colors.grey),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Profile Information Section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Profile Information',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const Divider(),

                      ...member.entries.map((entry) {
                        final key = entry.key;
                        final value = entry.value;

                        String displayValue;
                        if (value is Timestamp) {
                          displayValue = DateFormat('d-MMM-y, h:mm a').format(value.toDate());
                        } else if (value is List) {
                          displayValue = value.map((e) => e.toString()).join(', ');
                        } else {
                          displayValue = value.toString();
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(
                                  _beautifyKey(key),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 5,
                                child: Text(
                                  displayValue,
                                  style: const TextStyle(color: Colors.black87),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }


  String _beautifyKey(String key) {
    return key
        .replaceAllMapped(RegExp(r'([A-Z])'), (match) => ' ${match.group(1)}') // 👈 correct capture group
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp(r'^\w'), (m) => m.group(0)!.toUpperCase());
  }

  Widget _buildBirthdayList(List<Map<String, dynamic>> members) {
    members.sort((a, b) {
      final aDate = (a['dateOfBirth'] as Timestamp?)?.toDate();
      final bDate = (b['dateOfBirth'] as Timestamp?)?.toDate();
      return aDate?.compareTo(bDate ?? DateTime.now()) ?? 0;
    });

    final Map<String, List<Map<String, dynamic>>> groupedByDay = {};
    for (var member in members) {
      final dob = (member['dateOfBirth'] as Timestamp?)?.toDate();
      if (dob == null) continue;
      final birthdayThisYear = DateTime(DateTime.now().year, dob.month, dob.day);
      final weekday = DateFormat('EEEE').format(birthdayThisYear);
      groupedByDay.putIfAbsent(weekday, () => []).add(member);
    }

    return ListView(
      children: groupedByDay.entries.map((entry) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Text(entry.key, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ...entry.value.map((member) {
              final dob = (member['dateOfBirth'] as Timestamp?)?.toDate();
              if (dob == null) return const SizedBox.shrink();
              final birthdayThisYear = DateTime(DateTime.now().year, dob.month, dob.day);
              final age = birthdayThisYear.year - dob.year;
              final formattedDate = DateFormat('EEE, MMM d').format(dob);
              return ListTile(
                leading: _genderAvatar(member),
                title: Text('${member['firstName']} ${member['lastName']}'),
                subtitle: Text('Birthday: $formattedDate (Turning $age)'),
                trailing: IconButton(
                  icon: const Icon(Icons.card_giftcard, color: Colors.pink),
                  onPressed: () => _sendBirthdayWish(member),
                  tooltip: 'Send Birthday Wish',
                ),
              );
            }),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildMinistryList(List<Map<String, dynamic>> members) {
    final Set<String> allMinistries = {};
    for (var member in members) {
      final ministries = member['ministries'];
      if (ministries is List) {
        allMinistries.addAll(ministries.map((e) => e.toString()));
      }
    }

    final sortedMinistries = allMinistries.toList()..sort();
    final colors = [
      Colors.teal.shade200,
      Colors.orange.shade200,
      Colors.indigo.shade200,
      Colors.brown.shade200,
      Colors.green.shade200,
      Colors.blueGrey.shade200,
      Colors.pink.shade200,
      Colors.amber.shade200,
      Colors.red.shade200,
      Colors.cyan.shade200,
    ];

    Icon getMinistryIcon(String name) {
      final lower = name.toLowerCase();
      if (lower.contains('choir')) return const Icon(Icons.music_note, color: Colors.black);
      if (lower.contains('usher')) return const Icon(Icons.event_seat, color: Colors.black);
      if (lower.contains('prayer')) return const Icon(Icons.self_improvement, color: Colors.black);
      if (lower.contains('media')) return const Icon(Icons.videocam, color: Colors.black);
      if (lower.contains('children')) return const Icon(Icons.child_friendly, color: Colors.black);
      if (lower.contains('youth')) return const Icon(Icons.groups, color: Colors.black);
      if (lower.contains('hospitality')) return const Icon(Icons.local_cafe, color: Colors.black);
      if (lower.contains('security')) return const Icon(Icons.security, color: Colors.black);
      return const Icon(Icons.group_work, color: Colors.black);
    }

    int colorIndex = 0;

    return ListView(
      padding: const EdgeInsets.all(8),
      children: sortedMinistries.map((ministryName) {
        final ministryMembers = members.where((m) {
          final ministries = m['ministries'];
          return ministries is List && ministries.contains(ministryName);
        }).toList();

        final color = colors[colorIndex % colors.length];
        colorIndex++;

        return Card(
          elevation: 3,
          margin: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  getMinistryIcon(ministryName),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$ministryName (${ministryMembers.length})',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.black),
                    tooltip: 'Message Ministry',
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('📩 Message sent to $ministryName')),
                      );
                    },
                  ),
                ],
              ),
            ),
            children: ministryMembers.map((m) {
              return ListTile(
                leading: _genderAvatar(m),
                title: Text('${m['firstName']} ${m['lastName']}'),
                subtitle: m['role'] != null ? Text(m['role']) : null,
                onTap: () => _openMemberDetail(m),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }
  List<Map<String, dynamic>> _filterBirthdays(List<Map<String, dynamic>> members) {
    final now = DateTime.now();
    final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 6));

    return members.where((m) {
      final dobRaw = m['dateOfBirth'];
      final dob = dobRaw is Timestamp ? dobRaw.toDate() : null;
      if (dob == null) return false;
      final birthdayThisYear = DateTime(now.year, dob.month, dob.day);
      return birthdayThisYear.isAfter(startOfWeek.subtract(const Duration(days: 1))) &&
          birthdayThisYear.isBefore(endOfWeek.add(const Duration(days: 1)));
    }).toList();
  }
  List<Map<String, dynamic>> _filterNewMembers(List<Map<String, dynamic>> members) {
    return members.where((m) {
      final createdAt = m['createdAt'] is Timestamp ? (m['createdAt'] as Timestamp).toDate() : null;
      return createdAt != null && DateTime.now().difference(createdAt).inDays <= 2;
    }).toList();
  }
  List<Map<String, dynamic>> _filterInactive(List<Map<String, dynamic>> members) {
    return members.where((m) {
      final lastSeen = m['lastLogin'] is Timestamp ? (m['lastLogin'] as Timestamp).toDate() : null;
      return lastSeen == null || DateTime.now().difference(lastSeen).inDays > 30;
    }).toList();
  }
  Widget _buildGenderPieChart(List<Map<String, dynamic>> members) {
    final genderCounts = {
      'Male': 0,
      'Female': 0,
      'Other': 0,
    };

    for (final m in members) {
      final bucket = _genderBucket(m['gender']);
      if (bucket == 'male') {
        genderCounts['Male'] = (genderCounts['Male'] ?? 0) + 1;
      } else if (bucket == 'female') {
        genderCounts['Female'] = (genderCounts['Female'] ?? 0) + 1;
      } else {
        genderCounts['Other'] = (genderCounts['Other'] ?? 0) + 1;
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: PieChart(
        PieChartData(
          sections: genderCounts.entries.map((entry) {
            final color = entry.key == 'Male'
                ? Colors.blue
                : entry.key == 'Female'
                ? Colors.pink
                : Colors.grey;
            return PieChartSectionData(
              title: '${entry.key} (${entry.value})',
              value: entry.value.toDouble(),
              color: color,
              radius: 60,
              titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            );
          }).toList(),
        ),
      ),
    );
  }
  void _sendBirthdayWish(Map<String, dynamic> member) {
    final name = '${member['firstName']} ${member['lastName']}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🎉 Birthday wish sent to $name')),
    );
  }
  /*void _openMemberDetail(Map<String, dynamic> member) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${member['firstName']} ${member['lastName']}'),
        content: Text('Details for ${member['firstName'] ?? ''} will go here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }*/
  /*void _openMemberDetail(Map<String, dynamic> member) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${member['firstName'] ?? 'Unnamed'} ${member['lastName'] ?? ''}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: member.entries.map((entry) {
              final key = entry.key;
              final value = entry.value;

              // Format Timestamps
              if (value is Timestamp) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text(
                    '${_beautifyKey(key)}: ${DateFormat('yMMMd, h:mm a').format(value.toDate())}',
                    style: const TextStyle(fontSize: 14),
                  ),
                );
              }

              // Format lists like ministries
              if (value is List) {
                final listString = value.map((e) => e.toString()).join(', ');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Text(
                    '${_beautifyKey(key)}: $listString',
                    style: const TextStyle(fontSize: 14),
                  ),
                );
              }

              // Generic key-value display
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Text(
                  '${_beautifyKey(key)}: $value',
                  style: const TextStyle(fontSize: 14),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }*/

// Helper to format field names for display
 /* String _beautifyKey(String key) {
    return key
        .replaceAll(RegExp(r'([A-Z])'), ' \$1')
        .replaceAll('_', ' ')
        .replaceFirstMapped(RegExp(r'^\w'), (m) => m.group(0)!.toUpperCase());
  }*/

// Remaining methods (buildMinistryList, filter functions, chart, detail, birthday, etc.)
// have been updated with icons, colors, null-safety, and date parsing in the next section
// due to character limit. Let me know to continue from here with full continuity.
}
