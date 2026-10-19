import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  static final instance = AppSettings._();
  AppSettings._();
  bool darkMode = false;
  bool budgetEnabled = true;
  bool hideIncome = false;
  bool hideAssets = false;
  bool hideLiabilities = false;
  bool eyeComfort = true;
  int seedValue = 0xFF1677F2;
  Color get seed => Color(seedValue);
  static const colors = <String, int>{
    '蓝色': 0xFF1677F2, '青绿': 0xFF169B83, '紫色': 0xFF8064C5,
    '玫瑰': 0xFFCC607F, '暖橙': 0xFFCB7837,
  };
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    darkMode = prefs.getBool('dark_mode') ?? false;
    budgetEnabled = prefs.getBool('budget_enabled') ?? true;
    hideIncome = prefs.getBool('hide_home_income') ?? false;
    hideAssets = prefs.getBool('hide_assets') ?? false;
    hideLiabilities = prefs.getBool('hide_liabilities') ?? false;
    eyeComfort = prefs.getBool('eye_comfort') ?? true;
    final saved = prefs.getInt('theme_seed') ?? 0xFF1677F2;
    seedValue = colors.containsValue(saved) ? saved : 0xFF1677F2;
    notifyListeners();
  }
  Future<void> setDarkMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', value);
    darkMode = value;
    notifyListeners();
  }
  Future<void> setHideIncome(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool('hide_home_income', value)) throw StateError('Visibility setting was not saved');
    hideIncome = value;
    notifyListeners();
  }
  Future<void> setHideAssets(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool('hide_assets', value)) throw StateError('Visibility setting was not saved');
    hideAssets = value;
    notifyListeners();
  }
  Future<void> setHideLiabilities(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool('hide_liabilities', value)) throw StateError('Visibility setting was not saved');
    hideLiabilities = value;
    notifyListeners();
  }
  Future<void> setEyeComfort(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('eye_comfort', value);
    eyeComfort = value;
    notifyListeners();
  }
  Future<void> setBudgetEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('budget_enabled', value);
    budgetEnabled = value;
    notifyListeners();
  }
  Future<void> setSeed(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_seed', value);
    seedValue = value;
    notifyListeners();
  }
}

final budgetDataRevision = ValueNotifier<int>(0);
