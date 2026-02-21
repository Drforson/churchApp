import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import '../firebase_options.dart';

class AttendanceBackground {
  static const String _channelId = 'default_channel';
  static const String _channelName = 'General';
  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  static bool _notifReady = false;

  static Future<void> _ensureInitialized() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await _ensureNotificationsReady();
  }

  static Future<void> _ensureNotificationsReady() async {
    if (_notifReady) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _fln.initialize(settings: settings);
    final android =
        _fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'General notifications',
        importance: Importance.high,
      ),
    );
    _notifReady = true;
  }

  static Future<void> _notify(String title, String body) async {
    try {
      await _ensureNotificationsReady();
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

  @pragma('vm:entry-point')
  static Future<void> handleBackgroundPing(RemoteMessage message) async {
    await _ensureInitialized();
    final windowId = (message.data['windowId'] ?? '').toString().trim();
    await runAutoCheck(source: 'bg-fcm', windowId: windowId.isEmpty ? null : windowId);
  }

  static Future<void> runAutoCheck({
    required String source,
    String? windowId,
  }) async {
    await _ensureInitialized();

    final user = await _ensureUser();
    if (user == null) {
      return;
    }

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      await _notify('Attendance check-in', 'Enable location to check in.');
      return;
    }

    final perm = await Geolocator.checkPermission();
    // Background isolates cannot prompt for permission.
    if (perm == LocationPermission.denied) {
      await _notify('Attendance check-in', 'Allow location permission to check in.');
      return;
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.unableToDetermine) {
      await _notify('Attendance check-in', 'Enable location permission in Settings to check in.');
      return;
    }

    final winId = windowId ?? await _resolveActiveWindowId();
    if (winId == null || winId.isEmpty) {
      return;
    }

    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      return;
    }

    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('processAttendanceCheckin')
          .call({
            'windowId': winId,
            'deviceLocation': {'lat': pos.latitude, 'lng': pos.longitude},
            'accuracy': pos.accuracy,
          });
    } catch (e) {
    }
  }

  static Future<String?> _resolveActiveWindowId() async {
    final now = DateTime.now();
    try {
      final snap = await FirebaseFirestore.instance
          .collection('attendance_windows')
          .where('startsAt', isLessThanOrEqualTo: Timestamp.fromDate(now))
          .orderBy('startsAt', descending: true)
          .limit(10)
          .get();
      for (final d in snap.docs) {
        final data = d.data();
        final closed = data['closed'] == true;
        if (closed) continue;
        final endsAt = data['endsAt'] as Timestamp?;
        if (endsAt == null) continue;
        if (endsAt.toDate().isAfter(now)) return d.id;
      }
    } catch (e) {
    }
    return null;
  }

  static Future<User?> _ensureUser() async {
    final auth = FirebaseAuth.instance;
    User? user = auth.currentUser;
    if (user != null) return user;
    try {
      await auth.authStateChanges().first.timeout(const Duration(seconds: 3));
    } catch (_) {}
    return auth.currentUser;
  }
}
