import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

class EventsPage extends StatefulWidget {
  const EventsPage({super.key});

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');

  String? _uid;
  bool _isAdmin = false;
  bool _isPastor = false;
  bool _isLeader = false;
  Set<String> _leadershipMinistries = {};

  Future<List<_UiEvent>>? _externalFuture;

  bool get _canCreate => _isAdmin || _isPastor || _isLeader;

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;
    _externalFuture = _fetchGracepointEvents();
    _primeRole();
  }

  Future<void> _primeRole() async {
    final uid = _uid;
    if (uid == null) return;

    final token = await _auth.currentUser?.getIdTokenResult(true);
    final claims = token?.claims ?? const <String, dynamic>{};

    final userDoc = await _db.collection('users').doc(uid).get();
    final user = userDoc.data() ?? const <String, dynamic>{};
    final role = (user['role'] ?? '').toString().toLowerCase().trim();
    final roles = (user['roles'] is List)
        ? List<String>.from(
            (user['roles'] as List).map((e) => e.toString().toLowerCase()))
        : const <String>[];
    final memberId = (user['memberId'] ?? '').toString();
    final leadsFromUser = (user['leadershipMinistries'] is List)
        ? List<String>.from(
            (user['leadershipMinistries'] as List).map((e) => e.toString()))
        : const <String>[];

    bool isAdmin = role == 'admin' ||
        roles.contains('admin') ||
        user['isAdmin'] == true ||
        user['admin'] == true ||
        claims['isAdmin'] == true ||
        claims['admin'] == true;
    bool isPastor = role == 'pastor' ||
        roles.contains('pastor') ||
        user['isPastor'] == true ||
        user['pastor'] == true ||
        claims['isPastor'] == true ||
        claims['pastor'] == true;
    bool isLeader = role == 'leader' ||
        roles.contains('leader') ||
        user['isLeader'] == true ||
        user['leader'] == true ||
        claims['isLeader'] == true ||
        claims['leader'] == true ||
        leadsFromUser.isNotEmpty;

    final leadership = <String>{...leadsFromUser};

    if (memberId.isNotEmpty) {
      final memberDoc = await _db.collection('members').doc(memberId).get();
      final member = memberDoc.data() ?? const <String, dynamic>{};
      final mRoles = (member['roles'] is List)
          ? List<String>.from(
              (member['roles'] as List).map((e) => e.toString().toLowerCase()))
          : const <String>[];
      final mLeads = (member['leadershipMinistries'] is List)
          ? List<String>.from(
              (member['leadershipMinistries'] as List).map((e) => e.toString()))
          : const <String>[];
      leadership.addAll(mLeads);
      if (mRoles.contains('admin')) isAdmin = true;
      if (mRoles.contains('pastor') || member['isPastor'] == true)
        isPastor = true;
      if (mRoles.contains('leader') || mLeads.isNotEmpty) isLeader = true;
    }

    if (!mounted) return;
    setState(() {
      _isAdmin = isAdmin;
      _isPastor = isPastor;
      _isLeader = isLeader || isAdmin || isPastor;
      _leadershipMinistries = leadership;
    });
  }

  Stream<List<_UiEvent>> _upcomingLocalEvents() {
    return _db.collection('events').limit(500).snapshots().map((snap) {
      final now = DateTime.now();
      final all = snap.docs.map(_fromFirestore).toList();
      final upcoming = all.where((e) {
        final start = e.startDate;
        if (start == null) return true;
        return !start.isBefore(DateTime(now.year, now.month, now.day));
      }).toList();
      upcoming.sort((a, b) => (a.startDate ?? DateTime(1900))
          .compareTo(b.startDate ?? DateTime(1900)));
      return upcoming;
    });
  }

  _UiEvent _fromFirestore(DocumentSnapshot<Map<String, dynamic>> d) {
    final e = d.data() ?? const <String, dynamic>{};
    final start = _coerceDate(
      e['startDate'] ?? e['date'] ?? e['eventDate'] ?? e['scheduledAt'],
    );
    final end = _coerceDate(e['endDate']);
    return _UiEvent(
      id: d.id,
      title: (e['title'] ?? 'Untitled event').toString(),
      description: (e['description'] ?? '').toString(),
      startDate: start,
      endDate: end,
      location: (e['location'] ?? '').toString(),
      ministryId: (e['ministryId'] ?? '').toString(),
      source: _EventSource.local,
      link: null,
    );
  }

  DateTime? _coerceDate(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return _tryParseDate(v);
    return null;
  }

  Future<List<_UiEvent>> _fetchGracepointEvents() async {
    try {
      final fromCallable = await _fetchGracepointEventsViaCallable();
      if (fromCallable.isNotEmpty) return fromCallable;

      final out = <_UiEvent>[];
      out.addAll(await _fetchGracepointEventsFromApi());
      final pages = <String>[
        'https://gracepointuk.com/',
        'https://gracepointuk.com/events/',
        'https://gracepointuk.com/events-calendar/',
      ];
      final eventLinks = <String>{};

      for (final page in pages) {
        final res = await http.get(
          Uri.parse(page),
          headers: const {
            'User-Agent': 'Mozilla/5.0 (Flutter; ChurchApp)',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
        );
        if (res.statusCode < 200 || res.statusCode >= 300) continue;

        final doc = html_parser.parse(res.body);
        final scripts =
            doc.querySelectorAll('script[type="application/ld+json"]');
        for (final s in scripts) {
          final raw = s.text.trim();
          if (raw.isEmpty) continue;
          try {
            final parsed = jsonDecode(raw);
            _collectJsonLdEvents(parsed, out);
          } catch (_) {}
        }

        final anchors =
            doc.querySelectorAll('a[href*="?event="], a[href*="&event="]');
        for (final a in anchors) {
          final resolved = _resolveGracepointUrl(a.attributes['href'] ?? '');
          if (resolved != null) eventLinks.add(resolved);
        }
      }

      for (final url in eventLinks.take(24)) {
        final item = await _parseGracepointEventDetail(url);
        if (item != null) out.add(item);
      }

      if (out.isEmpty) {
        final links = await _discoverGracepointEventLinksFromSitemap();
        for (final url in links.take(30)) {
          final item = await _parseGracepointEventDetail(url);
          if (item != null) out.add(item);
        }
      }

      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      final filtered = out
          .where((e) => e.startDate == null || e.startDate!.isAfter(cutoff))
          .toList();
      filtered.sort((a, b) {
        final ad =
            a.startDate ?? DateTime.now().add(const Duration(days: 36500));
        final bd =
            b.startDate ?? DateTime.now().add(const Duration(days: 36500));
        return ad.compareTo(bd);
      });
      return filtered;
    } catch (_) {
      return const <_UiEvent>[];
    }
  }

  Future<List<_UiEvent>> _fetchGracepointEventsViaCallable() async {
    try {
      final res = await _functions.httpsCallable('getGracepointEvents').call();
      final data = (res.data is Map)
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};
      final list = (data['items'] is List)
          ? List<Map<String, dynamic>>.from(
              (data['items'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map)),
            )
          : const <Map<String, dynamic>>[];
      return list
          .map((e) {
            final start = _coerceDate(e['startDateIso']);
            return _UiEvent(
              id: (e['id'] ?? '').toString(),
              title: (e['title'] ?? '').toString(),
              description: (e['description'] ?? '').toString(),
              startDate: start,
              endDate: _coerceDate(e['endDateIso']),
              location: (e['location'] ?? '').toString(),
              ministryId: '',
              source: _EventSource.external,
              link: (e['link'] ?? '').toString().trim().isEmpty
                  ? null
                  : (e['link'] ?? '').toString().trim(),
            );
          })
          .where((e) => e.title.trim().isNotEmpty && e.startDate != null)
          .toList();
    } catch (_) {
      return const <_UiEvent>[];
    }
  }

  Future<List<_UiEvent>> _fetchGracepointEventsFromApi() async {
    final out = <_UiEvent>[];
    final endpoints = <String>[
      'https://gracepointuk.com/wp-json/tribe/events/v1/events',
      'https://gracepointuk.com/wp-json/wp/v2/tribe_events?per_page=100',
      'https://gracepointuk.com/wp-json/wp/v2/events?per_page=100',
    ];

    for (final url in endpoints) {
      try {
        final res = await http.get(
          Uri.parse(url),
          headers: const {
            'User-Agent': 'Mozilla/5.0 (Flutter; ChurchApp)',
            'Accept': 'application/json,text/plain,*/*',
          },
        );
        if (res.statusCode < 200 || res.statusCode >= 300) continue;
        final body = jsonDecode(res.body);

        if (body is Map && body['events'] is List) {
          for (final raw in body['events'] as List) {
            if (raw is! Map) continue;
            final title = _wpTitle(raw['title']);
            final start = _coerceDate(
                raw['start_date'] ?? raw['startDate'] ?? raw['date']);
            if (title.isEmpty || start == null) continue;
            out.add(_UiEvent(
              id: 'ext_${title.hashCode}_${start.millisecondsSinceEpoch}',
              title: title,
              description: _wpText(raw['description']),
              startDate: start,
              endDate: _coerceDate(raw['end_date'] ?? raw['endDate']),
              location: _wpText(raw['venue']),
              ministryId: '',
              source: _EventSource.external,
              link: _wpText(raw['url']),
            ));
          }
        } else if (body is List) {
          for (final raw in body) {
            if (raw is! Map) continue;
            final title = _wpTitle(raw['title']);
            final start = _coerceDate(
                raw['start_date'] ?? raw['date'] ?? raw['startDate']);
            if (title.isEmpty || start == null) continue;
            out.add(_UiEvent(
              id: 'ext_${title.hashCode}_${start.millisecondsSinceEpoch}',
              title: title,
              description: _wpText(raw['excerpt']) + _wpText(raw['content']),
              startDate: start,
              endDate: _coerceDate(raw['end_date'] ?? raw['endDate']),
              location: '',
              ministryId: '',
              source: _EventSource.external,
              link: _wpText(raw['link']),
            ));
          }
        }
      } catch (_) {}
    }

    return out;
  }

  String _wpTitle(dynamic value) {
    if (value is Map) {
      return _wpText(value['rendered']).trim();
    }
    return _wpText(value).trim();
  }

  String _wpText(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return '';
    try {
      return html_parser.parse(raw).body?.text.trim() ?? raw;
    } catch (_) {
      return raw;
    }
  }

  void _collectJsonLdEvents(dynamic node, List<_UiEvent> out) {
    if (node is List) {
      for (final n in node) {
        _collectJsonLdEvents(n, out);
      }
      return;
    }
    if (node is! Map) return;

    final type = (node['@type'] ?? '').toString().toLowerCase();
    if (type == 'event') {
      final title = (node['name'] ?? '').toString().trim();
      final startRaw = (node['startDate'] ?? '').toString().trim();
      final start = _tryParseDate(startRaw);
      if (title.isNotEmpty && start != null) {
        final location = node['location'] is Map
            ? ((node['location']['name'] ?? '').toString())
            : '';
        final link = (node['url'] ?? '').toString().trim();
        out.add(_UiEvent(
          id: 'ext_${title.hashCode}_${start.millisecondsSinceEpoch}',
          title: title,
          description: (node['description'] ?? '').toString(),
          startDate: start,
          endDate: _tryParseDate((node['endDate'] ?? '').toString()),
          location: location,
          ministryId: '',
          source: _EventSource.external,
          link: link.isEmpty ? null : link,
        ));
      }
    }

    for (final v in node.values) {
      _collectJsonLdEvents(v, out);
    }
  }

  DateTime? _tryParseDate(String raw) {
    if (raw.trim().isEmpty) return null;
    final clean =
        raw.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final iso = DateTime.tryParse(clean);
    if (iso != null) return iso;

    const fmts = <String>[
      'd MMM yyyy',
      'dd MMM yyyy',
      'd MMMM yyyy',
      'dd MMMM yyyy',
      'MMM d, yyyy',
      'MMMM d, yyyy',
      'EEE, d MMM yyyy',
      'EEEE, d MMMM yyyy',
    ];
    for (final f in fmts) {
      try {
        return DateFormat(f).parseLoose(clean);
      } catch (_) {}
    }
    final isoChunk =
        RegExp(r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})').firstMatch(clean);
    if (isoChunk != null) {
      return DateTime.tryParse(isoChunk.group(1)!.replaceFirst(' ', 'T'));
    }
    return null;
  }

  String? _resolveGracepointUrl(String href) {
    final h = href.trim();
    if (h.isEmpty) return null;
    if (h.startsWith('http://') || h.startsWith('https://')) return h;
    if (h.startsWith('/')) return 'https://gracepointuk.com$h';
    if (h.startsWith('?')) return 'https://gracepointuk.com/$h';
    return 'https://gracepointuk.com/$h';
  }

  Future<_UiEvent?> _parseGracepointEventDetail(String url) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Flutter; ChurchApp)',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final doc = html_parser.parse(res.body);
      final text = doc.body?.text ?? '';

      final title =
          (doc.querySelector('h1, h2, .entry-title')?.text ?? '').trim();
      if (title.isEmpty) return null;

      DateTime? start = _tryParseDate(text);
      final isoWrapped =
          RegExp(r'`(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})`').firstMatch(text);
      if (isoWrapped != null) {
        start ??=
            DateTime.tryParse(isoWrapped.group(1)!.replaceFirst(' ', 'T'));
      }
      if (start == null) return null;

      final location = (doc
                  .querySelector(
                      '.event-location, .location, .tribe-events-venue-details')
                  ?.text ??
              '')
          .trim();
      final description = (doc
                  .querySelector(
                      'p, .entry-summary, .tribe-events-single-event-description')
                  ?.text ??
              '')
          .trim();

      return _UiEvent(
        id: 'ext_${title.hashCode}_${start.millisecondsSinceEpoch}',
        title: title,
        description: description,
        startDate: start,
        endDate: null,
        location: location,
        ministryId: '',
        source: _EventSource.external,
        link: url,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _discoverGracepointEventLinksFromSitemap() async {
    final found = <String>{};
    final roots = <String>[
      'https://gracepointuk.com/sitemap_index.xml',
      'https://gracepointuk.com/wp-sitemap.xml',
    ];

    for (final root in roots) {
      try {
        final res = await http.get(
          Uri.parse(root),
          headers: const {'User-Agent': 'Mozilla/5.0 (Flutter; ChurchApp)'},
        );
        if (res.statusCode < 200 || res.statusCode >= 300) continue;
        final locs = RegExp(r'<loc>(.*?)</loc>', caseSensitive: false)
            .allMatches(res.body)
            .map((m) => m.group(1)?.trim() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();

        for (final loc in locs) {
          if (loc.contains('?event=')) {
            found.add(loc);
            continue;
          }
          if (!loc.endsWith('.xml')) continue;
          try {
            final child = await http.get(
              Uri.parse(loc),
              headers: const {'User-Agent': 'Mozilla/5.0 (Flutter; ChurchApp)'},
            );
            if (child.statusCode < 200 || child.statusCode >= 300) continue;
            final childLocs = RegExp(r'<loc>(.*?)</loc>', caseSensitive: false)
                .allMatches(child.body)
                .map((m) => m.group(1)?.trim() ?? '')
                .where((s) => s.contains('?event='))
                .toList();
            found.addAll(childLocs);
          } catch (_) {}
        }
      } catch (_) {}
    }
    return found.toList();
  }

  List<_UiEvent> _mergeAndDedupe(
      List<_UiEvent> local, List<_UiEvent> external) {
    final map = <String, _UiEvent>{};

    // Local first so it wins when duplicate appears on external site.
    for (final e in [...local, ...external]) {
      final k = _eventKey(e);
      map.putIfAbsent(k, () => e);
    }

    final all = map.values.toList();
    all.sort((a, b) {
      final ad = a.startDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.startDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      return ad.compareTo(bd);
    });
    return all;
  }

  String _eventKey(_UiEvent e) {
    final title = e.title.toLowerCase().trim();
    final day = e.startDate == null
        ? 'no-date'
        : DateFormat('yyyy-MM-dd').format(e.startDate!);
    return '$title|$day';
  }

  Future<void> _openCreator() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CreateEventSheet(
        canChurchWide: _isAdmin || _isPastor,
        leadershipMinistries: _leadershipMinistries.toList()..sort(),
      ),
    );
  }

  Future<void> _openLink(String? url) async {
    final u = (url ?? '').trim();
    if (u.isEmpty) return;
    final uri = Uri.tryParse(u);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upcoming Events')),
      floatingActionButton: _canCreate
          ? FloatingActionButton.extended(
              onPressed: _openCreator,
              icon: const Icon(Icons.add),
              label: const Text('Create Event'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          await _primeRole();
          setState(() => _externalFuture = _fetchGracepointEvents());
        },
        child: StreamBuilder<List<_UiEvent>>(
          stream: _upcomingLocalEvents(),
          builder: (context, localSnap) {
            if (localSnap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final local = localSnap.data ?? const <_UiEvent>[];
            return FutureBuilder<List<_UiEvent>>(
              future: _externalFuture,
              builder: (context, extSnap) {
                final external = extSnap.data ?? const <_UiEvent>[];
                final events = _mergeAndDedupe(local, external);

                if (events.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('No upcoming events.'),
                          const SizedBox(height: 8),
                          Text(
                            'Local: ${local.length} • Gracepoint: ${external.length}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Pull down to refresh.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return GridView.builder(
                  padding: const EdgeInsets.all(14),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.86,
                  ),
                  itemCount: events.length,
                  itemBuilder: (_, i) {
                    final e = events[i];
                    final dateStr = e.startDate == null
                        ? 'Date TBC'
                        : DateFormat('EEE, d MMM • h:mm a')
                            .format(e.startDate!.toLocal());
                    final sourceLabel = e.source == _EventSource.local
                        ? 'Church App'
                        : 'Gracepoint UK';
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: e.source == _EventSource.external
                          ? () => _openLink(e.link)
                          : null,
                      child: Ink(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.06),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                            const SizedBox(height: 8),
                            Text(dateStr,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            if (e.location.trim().isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                e.location.trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black87),
                              ),
                            ],
                            const Spacer(),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: e.source == _EventSource.local
                                        ? Colors.indigo.withOpacity(0.12)
                                        : Colors.teal.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    sourceLabel,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const Spacer(),
                                if (e.source == _EventSource.external)
                                  const Icon(Icons.open_in_new, size: 16),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

enum _EventSource { local, external }

class _UiEvent {
  final String id;
  final String title;
  final String description;
  final DateTime? startDate;
  final DateTime? endDate;
  final String location;
  final String ministryId;
  final _EventSource source;
  final String? link;

  const _UiEvent({
    required this.id,
    required this.title,
    required this.description,
    required this.startDate,
    required this.endDate,
    required this.location,
    required this.ministryId,
    required this.source,
    required this.link,
  });
}

class _CreateEventSheet extends StatefulWidget {
  final bool canChurchWide;
  final List<String> leadershipMinistries;

  const _CreateEventSheet({
    required this.canChurchWide,
    required this.leadershipMinistries,
  });

  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  final _db = FirebaseFirestore.instance;
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _location = TextEditingController();

  DateTime? _start;
  DateTime? _end;
  String _ministry = '';

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool start}) async {
    final base = start
        ? (_start ?? DateTime.now().add(const Duration(hours: 2)))
        : (_end ?? _start ?? DateTime.now().add(const Duration(hours: 3)));
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: base,
    );
    if (d == null) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (t == null) return;
    final dt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    setState(() {
      if (start) {
        _start = dt;
        if (_end != null && _end!.isBefore(_start!))
          _end = _start!.add(const Duration(hours: 1));
      } else {
        _end = dt;
      }
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_start == null) return;

    await _db.collection('events').add({
      'title': _title.text.trim(),
      'description': _description.text.trim(),
      'location': _location.text.trim(),
      'startDate': Timestamp.fromDate(_start!),
      'endDate': _end != null ? Timestamp.fromDate(_end!) : null,
      'ministryId': _ministry,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Event created')));
  }

  @override
  Widget build(BuildContext context) {
    final options = <String>[
      if (widget.canChurchWide) '',
      ...widget.leadershipMinistries,
    ].toSet().toList();

    if (!options.contains(_ministry))
      _ministry = options.isEmpty ? '' : options.first;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Form(
        key: _form,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text('Create Event',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(
                  labelText: 'Title', border: OutlineInputBorder()),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Description', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _location,
              decoration: const InputDecoration(
                  labelText: 'Location', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _pick(start: true),
              icon: const Icon(Icons.schedule),
              label: Text(_start == null
                  ? 'Pick start'
                  : DateFormat('EEE, d MMM • h:mm a')
                      .format(_start!.toLocal())),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _pick(start: false),
              icon: const Icon(Icons.schedule_send),
              label: Text(_end == null
                  ? 'Pick end (optional)'
                  : DateFormat('EEE, d MMM • h:mm a').format(_end!.toLocal())),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _ministry,
              items: options
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(m.isEmpty ? 'Church-wide' : m),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _ministry = v ?? ''),
              decoration: const InputDecoration(
                  labelText: 'Visibility', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
