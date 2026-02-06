// lib/pages/attendance_setup_page.dart
import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_google_places_sdk/flutter_google_places_sdk.dart';
import 'package:intl/intl.dart';

import '../secrets.dart';

class AttendanceSetupPage extends StatefulWidget {
  const AttendanceSetupPage({super.key});

  @override
  State<AttendanceSetupPage> createState() => _AttendanceSetupPageState();
}

class _AttendanceSetupPageState extends State<AttendanceSetupPage> {
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  final _auth = FirebaseAuth.instance;

  // ---- Place search
  late final FlutterGooglePlacesSdk _places;
  final _addrCtrl = TextEditingController();
  List<AutocompletePrediction> _predictions = [];
  Place? _selectedPlace;

  // ---- Window form
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController(text: 'Sunday Service');
  DateTime _serviceDate = DateTime.now();
  TimeOfDay _startTime = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 12, minute: 0);
  double _radiusMeters = 500;
  bool _creating = false;

  // ---- Override form (by memberId)
  final _overrideMemberIdCtrl = TextEditingController();
  final _overrideDateKeyCtrl =
  TextEditingController(text: _yyyyMmDd(DateTime.now()));
  bool _overriding = false;

  // ---- Role gate
  bool _authorized = false;
  bool _checkingAuth = true;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // The plugin requires an API key passed to the constructor.
    _places = FlutterGooglePlacesSdk(kGooglePlacesApiKey);

    _checkRoleClaims();
    _addrCtrl.addListener(_onAddressChanged);
  }

  @override
  void dispose() {
    _addrCtrl.removeListener(_onAddressChanged);
    _debounce?.cancel();
    _addrCtrl.dispose();
    _titleCtrl.dispose();
    _overrideMemberIdCtrl.dispose();
    _overrideDateKeyCtrl.dispose();
    super.dispose();
  }

  static String _yyyyMmDd(DateTime d) =>
      DateFormat('yyyy-MM-dd').format(DateTime(d.year, d.month, d.day));

  Future<void> _checkRoleClaims() async {
    try {
      final u = _auth.currentUser;
      if (u == null) {
        setState(() {
          _authorized = false;
          _checkingAuth = false;
        });
        return;
      }
      final token = await u.getIdTokenResult(true);
      final c = token.claims ?? {};
      // Allow admin, pastor, or leader
      final allowed = (c['admin'] == true ||
          c['isAdmin'] == true ||
          c['pastor'] == true ||
          c['isPastor'] == true ||
          c['leader'] == true ||
          c['isLeader'] == true);
      setState(() {
        _authorized = allowed;
        _checkingAuth = false;
      });
    } catch (_) {
      setState(() {
        _authorized = false;
        _checkingAuth = false;
      });
    }
  }

  void _onAddressChanged() {
    final q = _addrCtrl.text.trim();
    if (q.isEmpty) {
      setState(() {
        _predictions = [];
        _selectedPlace = null;
      });
      return;
    }
    _debouncedFindPredictions(q);
  }

  void _debouncedFindPredictions(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final res = await _places.findAutocompletePredictions(
          query,
          countries: const ['GB', 'US', 'NG', 'ZA', 'KE'],
          // placeTypesFilter can be added if you want to restrict types.
          newSessionToken: true,
        );
        if (!mounted) return;
        setState(() {
          _predictions = res.predictions;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _predictions = []);
      }
    });
  }

  Future<void> _selectPrediction(AutocompletePrediction p) async {
    try {
      final det = await _places.fetchPlace(
        p.placeId,
        fields: const [
          PlaceField.Address,
          PlaceField.Id,
          PlaceField.Location,
          PlaceField.Name,
          PlaceField.AddressComponents,
        ],
      );

      if (!mounted) return;

      final place = det.place; // may be null
      setState(() {
        _selectedPlace = place;
        final display = place?.address ?? place?.name;
        if (display != null) {
          _addrCtrl.text = display;
        }
        _predictions = [];
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to get place: $e')),
      );
    }
  }

  DateTime _combineLocal(DateTime day, TimeOfDay tod) =>
      DateTime(day.year, day.month, day.day, tod.hour, tod.minute);

  int _toUtcMillis(DateTime local) => local.toUtc().millisecondsSinceEpoch;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: _serviceDate,
    );
    if (picked != null) setState(() => _serviceDate = picked);
  }

  Future<void> _pickStartTime() async {
    final t = await showTimePicker(context: context, initialTime: _startTime);
    if (t != null) setState(() => _startTime = t);
  }

  Future<void> _pickEndTime() async {
    final t = await showTimePicker(context: context, initialTime: _endTime);
    if (t != null) setState(() => _endTime = t);
  }

  Future<void> _saveWindow({bool startNowQuick = false}) async {
    if (!_authorized) return;
    if (!_formKey.currentState!.validate()) return;
    if (_selectedPlace?.latLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a church address.')),
      );
      return;
    }

    final lat = _selectedPlace!.latLng!.lat;
    final lng = _selectedPlace!.latLng!.lng;
    final placeId = _selectedPlace?.id;
    final addr = _addrCtrl.text.trim();
    final title =
    _titleCtrl.text.trim().isEmpty ? 'Service' : _titleCtrl.text.trim();

    // Compute start/end timestamps (UTC)
    DateTime localStart = _combineLocal(_serviceDate, _startTime);
    DateTime localEnd = _combineLocal(_serviceDate, _endTime);

    // Quick “start now” test: start in ~2 minutes, 10-minute window
    if (startNowQuick) {
      final now = DateTime.now();
      localStart = now.add(const Duration(minutes: 2));
      localEnd = localStart.add(const Duration(minutes: 10));
    }

    if (localEnd.isBefore(localStart)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be after start time.')),
      );
      return;
    }

    final startsAt = _toUtcMillis(localStart);
    final endsAt = _toUtcMillis(localEnd);
    final dateKey = _yyyyMmDd(localStart);

    setState(() => _creating = true);
    try {
      await _functions.httpsCallable('upsertAttendanceWindow').call({
        'title': title,
        'dateKey': dateKey,
        'startsAt': startsAt,
        'endsAt': endsAt,
        'churchPlaceId': placeId,
        'radiusMeters': _radiusMeters.round(),
        'churchAddress': addr,
        'churchLocation': {'lat': lat, 'lng': lng},
        'source': 'flutter_setup_page',
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            startNowQuick
                ? 'Test window created. A ping will go out shortly.'
                : 'Attendance window saved for $dateKey.',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final parts = <String>[
        if (e.code.isNotEmpty) e.code,
        if ((e.message ?? '').trim().isNotEmpty) e.message!.trim(),
        if (e.details != null) e.details.toString(),
      ];
      final msg = parts.isEmpty ? 'Failed to save attendance window' : parts.join(' — ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _overrideStatus(String status) async {
    if (!_authorized) return;
    final memberId = _overrideMemberIdCtrl.text.trim();
    final dateKey = _overrideDateKeyCtrl.text.trim();
    if (memberId.isEmpty || dateKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter memberId and date (YYYY-MM-DD).')),
      );
      return;
    }

    setState(() => _overriding = true);
    try {
      await _functions.httpsCallable('overrideAttendanceStatus').call({
        'dateKey': dateKey,
        'memberId': memberId,
        'status': status, // 'present' or 'absent'
        'reason': 'Manual override from setup page',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Override saved: $memberId → $status')),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final parts = <String>[
        if (e.code.isNotEmpty) e.code,
        if ((e.message ?? '').trim().isNotEmpty) e.message!.trim(),
        if (e.details != null) e.details.toString(),
      ];
      final msg = parts.isEmpty ? 'Override failed' : parts.join(' — ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _overriding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingAuth) {
      return Scaffold(
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (kGooglePlacesApiKey.isEmpty) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Google Places API key is missing.\nSet GOOGLE_PLACES_API_KEY via --dart-define.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (!_authorized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Attendance Setup')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'You do not have permission to access this page.\n(Admin/Pastor/Leader only)',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final place = _selectedPlace;

    return Scaffold(
      appBar: AppBar(title: const Text('Attendance Setup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // === Church address (Places) ===
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Church Location',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _addrCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Search address or place',
                        prefixIcon: Icon(Icons.place),
                      ),
                    ),
                    if (_predictions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.white,
                        ),
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _predictions.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final p = _predictions[i];
                            return ListTile(
                              leading: const Icon(Icons.location_on),
                              title: Text(p.primaryText),
                              subtitle: p.secondaryText != null
                                  ? Text(p.secondaryText!)
                                  : null,
                              onTap: () => _selectPrediction(p),
                            );
                          },
                        ),
                      ),
                    ],
                    if (place?.latLng != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Selected: ${(place?.address ?? place?.name ?? _addrCtrl.text)}\n'
                                  'Lat: ${place!.latLng!.lat.toStringAsFixed(6)}, '
                                  'Lng: ${place.latLng!.lng.toStringAsFixed(6)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // === Service details ===
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      Text('Service Window',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Title',
                          prefixIcon: Icon(Icons.event_note),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _InfoButton(
                              label: 'Date',
                              value: DateFormat('EEE, d MMM yyyy')
                                  .format(_serviceDate),
                              icon: Icons.calendar_today,
                              onTap: _pickDate,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _InfoButton(
                              label: 'Start',
                              value: _startTime.format(context),
                              icon: Icons.schedule,
                              onTap: _pickStartTime,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _InfoButton(
                              label: 'End',
                              value: _endTime.format(context),
                              icon: Icons.timer_off,
                              onTap: _pickEndTime,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Radius'),
                          Expanded(
                            child: Slider(
                              value: _radiusMeters,
                              min: 100,
                              max: 1500,
                              divisions: 14,
                              label: '${_radiusMeters.round()} m',
                              onChanged: (v) =>
                                  setState(() => _radiusMeters = v),
                            ),
                          ),
                          SizedBox(
                            width: 72,
                            child: Text(
                              '${_radiusMeters.round()} m',
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.save),
                              onPressed: _creating
                                  ? null
                                  : () => _saveWindow(startNowQuick: false),
                              label: const Text('Save Window'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.bolt),
                              onPressed: _creating
                                  ? null
                                  : () => _saveWindow(startNowQuick: true),
                              label: const Text('Start Now (Test)'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // === Manual override ===
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('Manual Override',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _overrideMemberIdCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Member ID',
                        prefixIcon: Icon(Icons.badge),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _overrideDateKeyCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Date (YYYY-MM-DD)',
                        prefixIcon: Icon(Icons.today),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.check_circle),
                            onPressed: _overriding
                                ? null
                                : () => _overrideStatus('present'),
                            label: const Text('Mark Present'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: _overriding
                                ? null
                                : () => _overrideStatus('absent'),
                            label: const Text('Mark Absent'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  const _InfoButton({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.black54)),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
