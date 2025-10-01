
import 'package:flutter/material.dart';
import '../theme.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeData _themeData = AppThemes.memberTheme;

  ThemeData get themeData => _themeData;

  void setRole(String role) {
    if (role == 'admin') {
      _themeData = AppThemes.adminTheme;
    } else {
      _themeData = AppThemes.memberTheme;
    }
    notifyListeners();
  }
}
