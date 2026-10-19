import '../sync/sync_edit_guard.dart';
import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../models/tag.dart';

class TagManagementPage extends StatefulWidget {
  const TagManagementPage({super.key});

  @override
  State<TagManagementPage> createState() => _TagManagementPageState();
}

class _TagManagementPageState extends State<TagManagementPage> {
  @override
  void dispose() {
    _releaseSyncEdit();
    super.dispose();
  }

  final _releaseSyncEdit = SyncEditGuard.acquire();

  final DatabaseHelper _dbHelper = DatabaseHelper();
  List<Tag> _tags = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    setState(() => _isLoading = true);
    try {
      final tags = await _dbHelper.getAllTags(userId: 1);
      setState(() {
        _tags = tags;
        _isLoading = false;
      });
    } catch (e) {
      print('加载标签失败: $e');
      setState(() => _isLoading = false);
    }
  }

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (context) {
        String name = '';
        String? color = '#FF6B6B';

        return AlertDialog(
          title: const Text('添加标签'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: '标签名称',
                    hintText: '例如：外卖、聚餐',
                  ),
                  onChanged: (value) => name = value,
                ),
                const SizedBox(height: 16),
                const Text('选择颜色：'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _buildColorOption('#FF6B6B', currentColor: color),
                    _buildColorOption('#4ECDC4', currentColor: color),
                    _buildColorOption('#45B7D1', currentColor: color),
                    _buildColorOption('#96CEB4', currentColor: color),
                    _buildColorOption('#FFEAA7', currentColor: color),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入标签名称')),
                  );
                  return;
                }

                final tag = Tag(
                  name: name,
                  color: color,
                  userId: 1,
                );

                await _dbHelper.insertTag(tag);
                await _loadTags();
                Navigator.of(context).pop();
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildColorOption(String colorCode, {String? currentColor}) {
    return GestureDetector(
      onTap: () {
        // 这里需要更新选中的颜色
      },
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Color(int.parse(colorCode.substring(1), radix: 16) + 0xFF000000),
          shape: BoxShape.circle,
          border: currentColor == colorCode
              ? Border.all(color: Colors.black, width: 2)
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('标签管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddTagDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _tags.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.local_offer, size: 80, color: Colors.grey),
                      const SizedBox(height: 20),
                      const Text(
                        '暂无标签',
                        style: TextStyle(fontSize: 18, color: Colors.grey),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: _showAddTagDialog,
                        child: const Text('添加第一个标签'),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.2,
                  ),
                  itemCount: _tags.length,
                  itemBuilder: (context, index) {
                    final tag = _tags[index];
                    return Card(
                      color: tag.color != null
                          ? Color(int.parse(tag.color!.substring(1), radix: 16) + 0xFF000000)
                              .withOpacity(0.1)
                          : null,
                      child: Stack(
                        children: [
                          Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: tag.color != null
                                        ? Color(int.parse(tag.color!.substring(1), radix: 16) + 0xFF000000)
                                        : Colors.grey,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  tag.name,
                                  style: const TextStyle(fontSize: 12),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: IconButton(
                              icon: const Icon(Icons.delete, size: 16),
                              color: Colors.red,
                              onPressed: () async {
                                await _dbHelper.deleteTag(tag.id!);
                                await _loadTags();
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}