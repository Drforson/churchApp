import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:http/http.dart' as http;
import 'dart:convert';

class GivingPage extends StatefulWidget {
  const GivingPage({super.key});

  @override
  State<GivingPage> createState() => _GivingPageState();
}

class _GivingPageState extends State<GivingPage> {
  final TextEditingController _amountController = TextEditingController();
  bool _loading = false;

  void _launchPayPal() async {
    const url = 'https://www.paypal.com/donate?hosted_button_id=YOUR_BUTTON_ID';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw 'Could not launch $url';
    }
  }

  Future<void> _launchStripeCardPayment() async {
    final amount = _amountController.text.trim();
    if (amount.isEmpty || double.tryParse(amount) == null || double.parse(amount) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount')),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      final response = await http.post(
        Uri.parse('https://YOUR_CLOUD_FUNCTION_URL/payment_intent'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'amount': amount}),
      );
      final data = jsonDecode(response.body);

      await stripe.Stripe.instance.initPaymentSheet(
        paymentSheetParameters: stripe.SetupPaymentSheetParameters(
          paymentIntentClientSecret: data['clientSecret'],
          merchantDisplayName: 'Resurrection Church',
          style: ThemeMode.system,
        ),
      );

      await stripe.Stripe.instance.presentPaymentSheet();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you for your donation!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment failed: $e')),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Give to the Church'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFDFCFB), Color(0xFFE2EBF0)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Support Our Ministry',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ).animate().fade().slide(),
                const SizedBox(height: 12),
                const Text(
                  'Your giving helps us reach lives with the gospel, support our missions, and maintain church operations.',
                ).animate().fade().slide(),
              ],
            ),
            const SizedBox(height: 24),
            _buildGivingOption(
              context,
              icon: Icons.account_balance,
              title: 'Bank Transfer',
              description: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Account Name: Resurrection North London Church'),
                  Text('Account Number: 12345678'),
                  Text('Sort Code: 12-34-56'),
                ],
              ),
              buttonText: 'Use Details',
              onPressed: () {},
            ),
            const SizedBox(height: 16),
            _buildGivingOption(
              context,
              icon: Icons.paypal,
              title: 'PayPal',
              description: const Text('Quickly give through our secure PayPal portal.'),
              buttonText: 'Give via PayPal',
              onPressed: _launchPayPal,
            ),
            const SizedBox(height: 16),
            _buildGivingOption(
              context,
              icon: Icons.credit_card,
              title: 'Card Payment (via Stripe)',
              description: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Donate securely using your card.'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _amountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Amount in USD',
                      prefixText: '\$',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              buttonText: _loading ? 'Processing...' : 'Give with Card',
              onPressed: _loading ? null : _launchStripeCardPayment,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGivingOption(
      BuildContext context, {
        required IconData icon,
        required String title,
        required Widget description,
        required String buttonText,
        required VoidCallback? onPressed,
      }) {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 30, color: Colors.deepPurple),
                const SizedBox(width: 10),
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            description,
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: onPressed,
                child: Text(buttonText),
              ),
            ),
          ],
        ),
      ),
    ).animate().fade(duration: 400.ms).slideY();
  }
}
