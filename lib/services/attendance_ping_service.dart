import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AttendancePingService {
  AttendancePingService._();
  static final AttendancePingService I = AttendancePingService._();

  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  final _auth = FirebaseAuth.instance;
  final _messaging = FirebaseMessaging.instance;
  final _fln = FlutterLocalNotificationsPlugin();

  static const String _channelId = 'default_channel';
  static const String _channelName = 'General';

  GlobalKey<NavigatorState>? _navKey;
  bool _initialized = false;
  final Set<String> _handledWindowIds = <String>{};

  void init(GlobalKey<NavigatorState> navKey) {
    if (_initialized) return;
    _initialized = true;
    _navKey = navKey;

    _wireMessaging();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = _navKey?.currentContext;
      if (ctx == null) return;
      await ensureLocationReady(ctx, proactive: true);
    });
  }

  Future<void> _wireMessaging() async {
    FirebaseMessaging.onMessage.listen((m) {
      _handleMessage(m, source: 'foreground');
    });
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _handleMessage(m, source: 'opened');
    });
    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      _handleMessage(initial, source: 'initial');
    }
  }

  bool _isAttendancePing(RemoteMessage m) {
    final t = (m.data['type'] ?? '').toString().toLowerCase();
    return t == 'attendance_window_ping';
  }

  Future<void> _handleMessage(RemoteMessage m, {required String source}) async {
    if (!_isAttendancePing(m)) return;
    _showWelcomeNotification(
      title: (m.notification?.title ?? 'Welcome to service').toString(),
      body: (m.data['welcomeMessage'] ?? m.notification?.body ?? 'Attendance check-in is open.')
          .toString(),
    );
    final windowId = (m.data['windowId'] ?? '').toString().trim();
    if (windowId.isEmpty) return;
    if (_handledWindowIds.contains(windowId)) return;

    final ctx = _navKey?.currentContext;
    if (ctx == null) return;

    await _attemptCheckIn(ctx, windowId: windowId, source: source);
  }

  Future<void> _attemptCheckIn(
    BuildContext context, {
    required String windowId,
    required String source,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      _toast(context, 'Please sign in to record attendance.');
      return;
    }

    final ready = await ensureLocationReady(context, proactive: false);
    if (!ready) return;

    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      _toast(context, 'Could not get location: $e');
      return;
    }

    try {
      final res = await _functions.httpsCallable('processAttendanceCheckin').call({
        'windowId': windowId,
        'deviceLocation': {'lat': pos.latitude, 'lng': pos.longitude},
        'accuracy': pos.accuracy,
      });
      _handledWindowIds.add(windowId);

      final data = (res.data is Map) ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      final status = (data['status'] ?? '').toString();
      if (status == 'present') {
        final msg = 'Welcome! You are marked present.';
        _toast(context, msg);
        _showWelcomeNotification(title: 'Welcome', body: msg);
      } else if (status == 'absent') {
        _toast(context, '⚠️ You are outside the radius and marked absent.');
      } else {
        _toast(context, 'Attendance recorded.');
      }
    } on FirebaseFunctionsException catch (e) {
      final msg = (e.message ?? e.code).toString();
      _toast(context, 'Attendance check-in failed: $msg');
    } catch (e) {
      _toast(context, 'Attendance check-in failed: $e');
    }
  }

  Future<bool> ensureLocationReady(BuildContext context, {required bool proactive}) async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _showLocationDialog(
        context,
        title: 'Turn on location',
        message: 'Location is required to confirm attendance.',
        action: Geolocator.openLocationSettings,
      );
      return false;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      if (proactive) {
        _showLocationDialog(
          context,
          title: 'Allow location access',
          message: 'Please allow location access so we can confirm attendance.',
          action: Geolocator.openAppSettings,
        );
      }
      return false;
    }
    if (perm == LocationPermission.deniedForever) {
      _showLocationDialog(
        context,
        title: 'Location permission blocked',
        message: 'Enable location permission in Settings to use attendance check-in.',
        action: Geolocator.openAppSettings,
      );
      return false;
    }
    return true;
  }

  void _showLocationDialog(
    BuildContext context, {
    required String title,
    required String message,
    required Future<bool> Function() action,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await action();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _showWelcomeNotification({
    required String title,
    required String body,
  }) async {
    try {
      await _fln.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}
