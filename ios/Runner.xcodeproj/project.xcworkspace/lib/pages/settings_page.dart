import 'package:flutter/material.dart';
import '../models/app_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settings = AppSettings.instance;
  bool _saving = false;
  Future<void> _save(Future<void> Function() action) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置保存失败，请重试')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _section(String title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
        child: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      Card(child: Column(children: children)),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _settings,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('外观设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('外观', [
            SwitchListTile(
              title: const Text('夜间模式'),
              value: _settings.darkMode,
              subtitle: const Text('固定柔和深色，不随主题颜色变化'),
              onChanged: _saving
                  ? null
                  : (v) => _save(() => _settings.setDarkMode(v)),
            ),
            SwitchListTile(
              title: const Text('护眼配色'),
              subtitle: const Text('日间使用暖色背景和柔和的主题颜色'),
              value: _settings.eyeComfort,
              onChanged: _saving
                  ? null
                  : (v) => _save(() => _settings.setEyeComfort(v)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('日间主题颜色'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: AppSettings.colors.entries
                        .map(
                          (entry) => ChoiceChip(
                            avatar: CircleAvatar(
                              backgroundColor: Color(entry.value),
                              radius: 9,
                            ),
                            label: Text(entry.key),
                            selected: _settings.seedValue == entry.value,
                            onSelected: _saving
                                ? null
                                : (_) => _save(
                                    () => _settings.setSeed(entry.value),
                                  ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 20),
          const Center(
            child: Text(
              '外观设置自动保存',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
