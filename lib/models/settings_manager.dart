// settings_manager.dart
import 'package:shared_preferences/shared_preferences.dart';

class SettingsManager {
  static const _darkModeKey = 'dark_mode';
  static const _budgetEnabledKey = 'budget_enabled';
  static const _autoSyncKey = 'auto_sync';
  static const _backupEnabledKey = 'backup_enabled';
  static const _monthStartMondayKey = 'month_start_monday';
  static const _currencyKey = 'currency';
  static const _languageKey = 'language';
  
  static Future<bool> getDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_darkModeKey) ?? false;
  }
  
  static Future<void> setDarkMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModeKey, value);
  }
  
  static Future<bool> getBudgetEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_budgetEnabledKey) ?? true;
  }
  
  static Future<void> setBudgetEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_budgetEnabledKey, value);
  }
  
  static Future<bool> getAutoSync() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSyncKey) ?? false;
  }
  
  static Future<void> setAutoSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSyncKey, value);
  }
  
  static Future<bool> getBackupEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_backupEnabledKey) ?? true;
  }
  
  static Future<void> setBackupEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backupEnabledKey, value);
  }
  
  static Future<bool> getMonthStartMonday() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_monthStartMondayKey) ?? false;
  }
  
  static Future<void> setMonthStartMonday(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_monthStartMondayKey, value);
  }
  
  static Future<String> getCurrency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_currencyKey) ?? 'CNY';
  }
  
  static Future<void> setCurrency(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currencyKey, value);
  }
  
  static Future<String> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languageKey) ?? 'zh-CN';
  }
  
  static Future<void> setLanguage(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, value);
  }
  
  // 清除所有设置
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_darkModeKey);
    await prefs.remove(_budgetEnabledKey);
    await prefs.remove(_autoSyncKey);
    await prefs.remove(_backupEnabledKey);
    await prefs.remove(_monthStartMondayKey);
    await prefs.remove(_currencyKey);
    await prefs.remove(_languageKey);
  }
  
  // 重置为默认值
  static Future<void> resetToDefaults() async {
    await setDarkMode(false);
    await setBudgetEnabled(true);
    await setAutoSync(false);
    await setBackupEnabled(true);
    await setMonthStartMonday(false);
    await setCurrency('CNY');
    await setLanguage('zh-CN');
  }
}

// 在 settings_manager.dart 中添加以下代码
// 或者创建一个新的 ledger_settings_manager.dart 文件

class LedgerSettingsManager {
  static const _currentLedgerIdKey = 'current_ledger_id';
  static const _currentMonthOffsetKey = 'current_month_offset';
  
  // 获取当前选中的账本ID
  static Future<int> getCurrentLedgerId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_currentLedgerIdKey) ?? 1; // 默认使用ID为1的账本（总账本）
  }
  
  // 设置当前选中的账本ID
  static Future<void> setCurrentLedgerId(int ledgerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_currentLedgerIdKey, ledgerId);
  }
  
  // 获取当前月份偏移量
  static Future<int> getCurrentMonthOffset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_currentMonthOffsetKey) ?? 0; // 0表示当前月
  }
  
  // 设置当前月份偏移量
  static Future<void> setCurrentMonthOffset(int offset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_currentMonthOffsetKey, offset);
  }
}
