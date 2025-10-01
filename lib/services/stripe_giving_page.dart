import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class StripeGivingPage extends StatefulWidget {
  const StripeGivingPage({super.key});

  @override
  State<StripeGivingPage> createState() => _StripeGivingPageState();
}

class _StripeGivingPageState extends State<StripeGivingPage> {
  final _amountController = TextEditingController();
  bool _loading = false;

  Future<void> _makePayment() async {
    final amount = _amountController.text.trim();
    if (amount.isEmpty) return;

    setState(() => _loading = true);

    try {
      // STEP 1: Create payment intent on server
      final response = await http.post(
        Uri.parse('https://YOUR_CLOUD_FUNCTION_URL/payment_intent'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'amount': amount}),
      );
      final data = jsonDecode(response.body);

      // STEP 2: Initialize payment sheet
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: data['clientSecret'],
          merchantDisplayName: 'Resurrection Church',
          style: ThemeMode.system,
        ),
      );

      // STEP 3: Present payment sheet
      await Stripe.instance.presentPaymentSheet();

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
      appBar: AppBar(title: const Text('Give with Stripe')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Enter donation amount'),
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(prefixText: '\$', hintText: 'e.g. 50'),
            ),
            const SizedBox(height: 20),
            _loading
                ? const CircularProgressIndicator()
                : ElevatedButton(
              onPressed: _makePayment,
              child: const Text('Donate'),
            ),
          ],
        ),
      ),
    );
  }
}
