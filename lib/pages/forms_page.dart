import 'package:flutter/material.dart';

class FormsPage extends StatelessWidget {
  const FormsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <_ActionItem>[
      _ActionItem('Prayer Request', Icons.volunteer_activism_rounded, '/form-prayer-request'),
      _ActionItem('Baptism Request', Icons.water_drop_rounded, '/form-baptism-interest'),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Forms & Sign-Ups')),
      body: LayoutBuilder(
        builder: (context, c) {
          final columns = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 600 ? 2 : 1);
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.15,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => _ActionCard(item: items[i]),
          );
        },
      ),
    );
  }
}

class _ActionItem {
  final String label;
  final IconData icon;
  final String route;
  const _ActionItem(this.label, this.icon, this.route);
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
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const SizedBox(height: 8),
              CircleAvatar(
                radius: 28,
                backgroundColor: const Color(0xFFE8ECF3),
                child: Icon(item.icon, size: 28, color: Colors.indigo),
              ),
              const Spacer(),
              Text(
                item.label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Align(
                alignment: Alignment.bottomRight,
                child: Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
