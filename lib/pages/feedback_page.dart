// lib/pages/feedback_page.dart
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _formKey = GlobalKey<FormState>();

  // form fields
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _stepsCtrl = TextEditingController();
  final _expectedCtrl = TextEditingController();
  final _actualCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  String _category = 'Bug';
  String _severity = 'Medium';
  double _rating = 3;
  bool _allowContact = true;
  bool _anonymous = false;
  String _environment = 'Testing';

  // screenshots
  final List<File> _screenshots = [];
  bool _submitting = false;

  // context info
  Map<String, dynamic> _deviceInfo = {};
  Map<String, dynamic> _appInfo = {};

  @override
  void initState() {
    super.initState();
    _primeInfo();
  }

  Future<void> _primeInfo() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      _appInfo = {
        'appName': pkg.appName,
        'packageName': pkg.packageName,
        'version': pkg.version,
        'buildNumber': pkg.buildNumber,
      };

      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await deviceInfo.androidInfo;
        _deviceInfo = {
          'platform': 'android',
          'model': a.model,
          'device': a.device,
          'brand': a.brand,
          'androidVersion': a.version.release,
          'sdkInt': a.version.sdkInt,
        };
      } else if (Platform.isIOS) {
        final i = await deviceInfo.iosInfo;
        _deviceInfo = {
          'platform': 'ios',
          'name': i.name,
          'model': i.model,
          'systemName': i.systemName,
          'systemVersion': i.systemVersion,
        };
      } else {
        _deviceInfo = {'platform': 'other'};
      }

      final user = _auth.currentUser;
      if (user != null && (user.email ?? '').isNotEmpty) {
        _emailCtrl.text = user.email!;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _pickScreenshot() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (x != null) {
      setState(() => _screenshots.add(File(x.path)));
    }
  }

  Future<List<String>> _uploadScreenshots(String docId) async {
    final uid = _auth.currentUser?.uid ?? 'anon';
    final storage = FirebaseStorage.instance;
    final List<String> urls = [];
    for (var i = 0; i < _screenshots.length; i++) {
      final file = _screenshots[i];
      final ref = storage.ref().child('feedback_uploads/$uid/$docId/scr_$i.jpg');
      await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      urls.add(url);
    }
    return urls;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    final uid = _auth.currentUser?.uid;
    final now = FieldValue.serverTimestamp();

    try {
      // 1) create placeholder feedback doc
      final ref = _db.collection('app_feedback').doc();
      await ref.set({
        'id': ref.id,
        'createdAt': now,
        'updatedAt': now,
        'uid': _anonymous ? null : uid,
        'email': _anonymous ? null : (_emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim()),
        'allowContact': _allowContact && !_anonymous,
        'anonymous': _anonymous,
        'category': _category,
        'severity': _severity,
        'rating': _rating, // 1-5
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'stepsToReproduce': _stepsCtrl.text.trim().isEmpty ? null : _stepsCtrl.text.trim(),
        'expected': _expectedCtrl.text.trim().isEmpty ? null : _expectedCtrl.text.trim(),
        'actual': _actualCtrl.text.trim().isEmpty ? null : _actualCtrl.text.trim(),
        'environment': _environment, // Testing/Production/etc.
        'device': _deviceInfo,
        'app': _appInfo,
        'status': 'open',         // open → triaged → in_progress → resolved → closed
        'assignee': null,         // staff uid later
        'tags': [],               // triage can set tags
        'screenshotUrls': [],
      });

      // 2) upload screenshots (optional) and patch
      List<String> urls = [];
      if (_screenshots.isNotEmpty) {
        urls = await _uploadScreenshots(ref.id);
        await ref.update({'screenshotUrls': urls, 'updatedAt': now});
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks! Your feedback was submitted.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submit failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _stepsCtrl.dispose();
    _expectedCtrl.dispose();
    _actualCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send Feedback'),
        actions: [
          IconButton(
            tooltip: 'Submit',
            icon: const Icon(Icons.send),
            onPressed: _submitting ? null : _submit,
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _submitting,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Section: Quick context
              Row(
                children: [
                  Expanded(
                    child: _DropdownField<String>(
                      label: 'Category',
                      value: _category,
                      items: const ['Bug', 'Feature request', 'Design/UI', 'Performance', 'Other'],
                      onChanged: (v) => setState(() => _category = v ?? 'Bug'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DropdownField<String>(
                      label: 'Severity',
                      value: _severity,
                      items: const ['Low', 'Medium', 'High', 'Critical'],
                      onChanged: (v) => setState(() => _severity = v ?? 'Medium'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _DropdownField<String>(
                      label: 'Environment',
                      value: _environment,
                      items: const ['Testing', 'Staging', 'Production', 'Unknown'],
                      onChanged: (v) => setState(() => _environment = v ?? 'Testing'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _RatingField(
                      label: 'App rating',
                      value: _rating,
                      onChanged: (v) => setState(() => _rating = v),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              TextFormField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Short title',
                  hintText: 'E.g., Crash when opening Events page',
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Title is required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What happened? Add any helpful details.',
                ),
                minLines: 4,
                maxLines: 8,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Description is required' : null,
              ),

              const SizedBox(height: 16),
              Text('Reproduction details', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextFormField(
                controller: _stepsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Steps to reproduce (optional)',
                  hintText: '1) Open app  2) Tap Ministries  3) Press +  4) Crash...',
                ),
                minLines: 3,
                maxLines: 6,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _expectedCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Expected (optional)',
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _actualCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Actual (optional)',
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              Text('Screenshots (optional)', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < _screenshots.length; i++)
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(_screenshots[i], width: 100, height: 100, fit: BoxFit.cover),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: InkWell(
                            onTap: () => setState(() => _screenshots.removeAt(i)),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Icon(Icons.close, size: 16, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                  OutlinedButton.icon(
                    onPressed: _pickScreenshot,
                    icon: const Icon(Icons.add_photo_alternate),
                    label: const Text('Add screenshot'),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              Text('Contact (optional)', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _anonymous,
                onChanged: (v) => setState(() {
                  _anonymous = v;
                  if (v) _allowContact = false;
                }),
                title: const Text('Send anonymously'),
                subtitle: const Text('We will not store your email or user ID'),
              ),
              if (!_anonymous) ...[
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                    hintText: 'If we need more details',
                  ),
                ),
                CheckboxListTile(
                  value: _allowContact,
                  onChanged: (v) => setState(() => _allowContact = v ?? false),
                  title: const Text('Allow us to contact you for clarifications'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],

              const SizedBox(height: 24),
              FilledButton.icon(
                icon: _submitting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                label: const Text('Submit feedback'),
                onPressed: _submitting ? null : _submit,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final ValueChanged<T?> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      isExpanded: true, // <-- prevents RenderFlex overflow
      decoration: InputDecoration(
        labelText: label,
        isDense: true, // a bit more compact; also helps on tight widths
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      value: value,
      items: items
          .map(
            (e) => DropdownMenuItem<T>(
          value: e,
          child: Text(
            e.toString(),
            overflow: TextOverflow.ellipsis, // <-- long text won't overflow
            maxLines: 1,
            softWrap: false,
          ),
        ),
      )
          .toList(),
      onChanged: onChanged,
    );
  }
}


class _RatingField extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _RatingField({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Slider(
          value: value,
          min: 1,
          max: 5,
          divisions: 4,
          label: value.toStringAsFixed(0),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
