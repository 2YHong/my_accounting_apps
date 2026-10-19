import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../database/database_helper.dart';
import '../models/asset_account.dart';
import '../models/app_settings.dart';
import 'edit_account_page.dart';
import '../services/asset_account_service.dart';
import '../services/asset_notifications.dart';
import '../services/bill_csv_service.dart' show billDataRevision;

class AssetsPage extends StatefulWidget {
  const AssetsPage({super.key});

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  final DatabaseHelper _dbHelper = DatabaseHelper();
  
  // 数据状态
  List<AssetAccount> _accounts = [];
  double _totalAssets = 0.0;
  double _totalLiabilities = 0.0;
  bool _isLoading = true;
  int _loadSequence = 0;
  String? _loadError;
  final _accountService = AssetAccountService();
  bool _deletingAccount = false;

  @override
  void initState() {
    super.initState();
    assetAccountsRevision.addListener(_onAccountsChanged);
    billDataRevision.addListener(_onAccountsChanged);
    AppSettings.instance.addListener(_onPrivacyChanged);
    _loadAssetsData();
  }

  @override
  void dispose() {
    assetAccountsRevision.removeListener(_onAccountsChanged);
    billDataRevision.removeListener(_onAccountsChanged);
    AppSettings.instance.removeListener(_onPrivacyChanged);
    super.dispose();
  }

  void _onAccountsChanged() {
    _loadAssetsData();
  }

  void _onPrivacyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleAmountVisibility(bool liability) async {
    final settings = AppSettings.instance;
    try {
      if (liability) {
        await settings.setHideLiabilities(!settings.hideLiabilities);
      } else {
        await settings.setHideAssets(!settings.hideAssets);
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('隐藏设置保存失败，请重试')));
    }
  }

  Future<void> _loadAssetsData() async {
    final sequence = ++_loadSequence;
    try {
      final user = await _dbHelper.getCurrentUser();
      final accounts = await _dbHelper.getAllAssetAccounts(userId: user.id);
      final totalAssets = accounts.where((account) => account.type != 'loan')
          .fold<double>(0, (total, account) => total + account.balance);
      final totalLiabilities = accounts.where((account) => account.type == 'loan')
          .fold<double>(0, (total, account) => total + account.balance);
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _accounts = accounts;
        _totalAssets = totalAssets;
        _totalLiabilities = totalLiabilities;
        _isLoading = false;
        _loadError = null;
      });
    } catch (_) {
      if (mounted && sequence == _loadSequence) {
        setState(() { _isLoading = false; _loadError = '账户加载失败，请下拉重试'; });
      }
    }
  }

  // 按类型分组账户
  // 按类型分组账户
Map<String, List<AssetAccount>> _groupAccountsByType() {
  final Map<String, List<AssetAccount>> grouped = {
    '资产账户': [],
    '负债账户': [],  // 改为借贷账户
  };
  
  for (final account in _accounts) {
    if (account.type == 'loan') {  // 判断是否为借贷账户
      grouped['负债账户']!.add(account);
    } else {
      grouped['资产账户']!.add(account);
    }
  }
  
  return grouped;
}


  // 添加新账户
  Future<void> _addNewAccount() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (context) => const EditAccountPage(),
      ),
    );
    
    // 如果返回结果需要刷新，则重新加载数据
    if (!mounted) return;
    if (result != null && (result['refresh'] == true || result['deleted'] == true)) {
      await _loadAssetsData();
    } else if (result == null) {
      // 如果正常返回，也刷新数据
      await _loadAssetsData();
    }
  }

  // 编辑账户
  Future<void> _editAccount(AssetAccount account) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (context) => EditAccountPage(account: account),
      ),
    );
    
    // 根据返回结果刷新数据
    if (!mounted) return;
    if (result != null && (result['refresh'] == true || result['deleted'] == true)) {
      await _loadAssetsData();
    } else if (result == null) {
      // 如果正常返回，也刷新数据
      await _loadAssetsData();
    }
  }

  Future<void> _deleteAccount(AssetAccount account) async {
    if (_deletingAccount) return;
    setState(() => _deletingAccount = true);
    try {
      final count = await _accountService.linkedBillCount(account);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除账户'),
          content: Text(count == 0 ? '确定删除「${account.name}」吗？'
            : '「${account.name}」关联了 $count 条账单。删除后账单全部保留，付款或收款账户改为“不关联账户”。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
              child: const Text('删除账户')),
          ],
        ));
      if (confirmed != true || !mounted) return;
      await _accountService.delete(account);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除「${account.name}」，账单已保留')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败，请重试')));
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  // ==================== 界面组件 ====================
  Widget _buildAssetsLiabilitiesCard() => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(children: [
        Expanded(child: _buildTotalColumn(liability: false)),
        Container(width: 1, height: 72,
          color: Theme.of(context).colorScheme.outlineVariant),
        Expanded(child: _buildTotalColumn(liability: true)),
      ])),
  );

  Widget _buildTotalColumn({required bool liability}) {
    final scheme = Theme.of(context).colorScheme;
    final title = liability ? '总负债' : '总资产';
    final hidden = liability ? AppSettings.instance.hideLiabilities : AppSettings.instance.hideAssets;
    final total = liability ? _totalLiabilities : _totalAssets;
    final count = _accounts.where((account) => liability ? account.type == 'loan' : account.type != 'loan').length;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(child: Text(title, maxLines: 1, softWrap: false,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant))),
          IconButton(
            tooltip: hidden ? '显示$title金额' : '隐藏$title金额',
            onPressed: () => _toggleAmountVisibility(liability),
            iconSize: 20,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            padding: const EdgeInsets.all(8),
            icon: Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
          ),
        ]),
        SizedBox(height: 32, child: hidden ? const SizedBox.expand()
          : FittedBox(fit: BoxFit.scaleDown, child: Text('¥${total.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600,
                color: liability ? scheme.error : const Color(0xFF318675))))),
        const SizedBox(height: 6),
        Text('$count个账户', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]));
  }

  // 2. 资产分布环形图
 // 2. 资产分布环形图（只显示资产账户）
Widget _buildAssetRingChart() {
  final accounts = _accounts.where((a) => a.type != 'loan' && a.balance.isFinite && a.balance > 0).toList()
    ..sort((a, b) => b.balance.compareTo(a.balance));
  final total = accounts.fold<double>(0, (sum, a) => sum + a.balance);
  final colors = [Theme.of(context).colorScheme.primary, const Color(0xFF169B83),
    const Color(0xFFF29D38), const Color(0xFF8B69CE), const Color(0xFFDF6B9B), const Color(0xFF8D98A8)];
  final visible = accounts.take(5).toList();
  final remaining = accounts.skip(5).fold<double>(0, (sum, a) => sum + a.balance);
  final values = [...visible.map((a) => a.balance), if (remaining > 0) remaining];
  final names = [...visible.map((a) => a.name), if (remaining > 0) '其他账户'];
  return Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('资产分布', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      const SizedBox(height: 18),
      if (total <= 0) const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('暂无正余额资产')))
      else ...[
        SizedBox(height: 200, child: Stack(alignment: Alignment.center, children: [
          PieChart(PieChartData(centerSpaceRadius: 62, sectionsSpace: 3,
            pieTouchData: PieTouchData(enabled: false),
            sections: [for (var i = 0; i < values.length; i++) PieChartSectionData(
              value: values[i], color: colors[i], radius: 32, showTitle: false)],
          )),
          Text('${accounts.length}个账户', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
        const SizedBox(height: 14),
        Wrap(spacing: 16, runSpacing: 12, children: [for (var i = 0; i < values.length; i++)
          Text('● ${names[i]} ${(values[i] / total * 100).toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 12, color: colors[i]))]),
        if (_accounts.any((a) => a.type != 'loan' && a.balance <= 0))
          const Padding(padding: EdgeInsets.only(top: 12), child: Text('零余额及负余额账户不计入分布比例', style: TextStyle(fontSize: 11, color: Colors.grey))),
      ],
    ])));
}

  // 3. 账户分组卡片
  Widget _buildAccountGroupCard(String title, List<AssetAccount> accounts, double total, Color color) {
    final isAssetGroup = title == '资产账户';
    final hidden = isAssetGroup ? AppSettings.instance.hideAssets : AppSettings.instance.hideLiabilities;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题和总计
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 16,
                      color: color,
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    )),
                  ],
                )),
                if (!hidden) Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(
                  '¥${total.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ))),
              ],
            ),
            const SizedBox(height: 12),
            
            // 账户列表
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: accounts.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final account = accounts[index];
                return _buildAccountListItem(account);
              },
            ),
            
            // 添加账户按钮（仅资产账户组显示）
            if (isAssetGroup)
              Column(
                children: [
                  const Divider(height: 20),
                  OutlinedButton.icon(
                    onPressed: _addNewAccount,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加账户'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 40),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // 4. 账户列表项
  Widget _buildAccountListItem(AssetAccount account) {
    final isLiability = account.type == 'loan';
    final hidden = isLiability ? AppSettings.instance.hideLiabilities : AppSettings.instance.hideAssets;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(onTap: () => _editAccount(account),
      borderRadius: BorderRadius.circular(12),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 19,
              backgroundColor: _getAccountColor(account.type).withValues(alpha: .12),
              child: Icon(_getAccountIconData(account.type), size: 20,
                color: _getAccountColor(account.type))),
            const SizedBox(width: 10),
            Expanded(child: Text(account.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16))),
            if (!hidden) Padding(padding: const EdgeInsets.only(left: 8),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 120),
                child: FittedBox(fit: BoxFit.scaleDown, child: Text('¥${account.balance.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 16, color: isLiability ? scheme.error : const Color(0xFF318675)))))),
            PopupMenuButton<String>(tooltip: '账户操作', enabled: !_deletingAccount,
              onSelected: (action) {
                if (action == 'edit') { _editAccount(account); }
                else { _deleteAccount(account); }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('编辑账户')),
                PopupMenuItem(value: 'delete', child: Text('删除账户',
                  style: TextStyle(color: scheme.error))),
              ]),
          ]),
          Padding(padding: const EdgeInsets.only(left: 48), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 12, runSpacing: 4, children: [
                Text(_getAccountTypeLabel(account.type),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                if (account.cardNumberLastFour?.isNotEmpty == true)
                  Text('尾号 ${account.cardNumberLastFour}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
              if (!hidden && isLiability && account.creditLimit != null) ...[
                const SizedBox(height: 5),
                Text('贷款总额 ¥${account.creditLimit!.toStringAsFixed(2)} · 剩余 ¥${(account.creditLimit! - account.balance).toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ])),
        ])));
  }

  // ==================== 辅助方法 ====================
  // 获取账户颜色
Color _getAccountColor(String type) {
  switch (type) {
    case 'digital': return Colors.blue;
    case 'cash': return Colors.green;
    case 'bank': return Colors.red;
    case 'loan': return Colors.orange;  // 改为 loan（借贷）
    case 'investment': return Colors.purple;
    default: return Colors.grey;
  }
}

// 获取账户图标
IconData _getAccountIconData(String type) {
  switch (type) {
    case 'digital': return Icons.phone_android;
    case 'cash': return Icons.money;
    case 'bank': return Icons.account_balance;
    case 'loan': return Icons.money_off;  // 改为借贷图标
    case 'investment': return Icons.trending_up;
    default: return Icons.account_balance_wallet;
  }
}

// 获取账户类型标签
String _getAccountTypeLabel(String type) {
  switch (type) {
    case 'digital': return '电子钱包';
    case 'cash': return '现金';
    case 'bank': return '银行卡';
    case 'loan': return '借贷账户';  // 改为借贷账户
    case 'investment': return '投资账户';
    case 'custom': return '自定义';
    default: return '未知类型';
  }
}

// 图例项方法（新增）
// 在图例项方法（需要在 _buildAssetRingChart 方法之前定义）


  // ==================== 主界面 ====================
  @override
Widget build(BuildContext context) {
  final groupedAccounts = _groupAccountsByType();
  final assetAccounts = groupedAccounts['资产账户']!;
  final liabilityAccounts = groupedAccounts['负债账户']!;
  final assetTotal = assetAccounts.fold<double>(0, (sum, account) => sum + account.balance);
  final liabilityTotal = liabilityAccounts.fold<double>(0, (sum, account) => sum + account.balance);
  
  return Scaffold(
    appBar: AppBar(
      title: const Text('资产'),
    ),
    body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _loadAssetsData,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16.0),
              children: [
                if (_loadError != null) Padding(padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_loadError!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                // 1. 资产和负债卡片（修改后）
                _buildAssetsLiabilitiesCard(),  // 改为新的卡片
                const SizedBox(height: 20),
                
                // 2. 资产分布环形图（修改后，只显示资产）
                _buildAssetRingChart(),
                const SizedBox(height: 20),
                
                // 3. 资产账户列表
                if (assetAccounts.isNotEmpty)
                  _buildAccountGroupCard(
                    '资产账户',
                    assetAccounts,
                    assetTotal,
                    Colors.green,
                  ),
                
                if (assetAccounts.isNotEmpty) 
                  const SizedBox(height: 20),
                
                // 4. 负债账户列表（改为借贷账户）
                if (liabilityAccounts.isNotEmpty)
                  _buildAccountGroupCard(
                    '借贷账户',  // 修改标题
                    liabilityAccounts,
                    liabilityTotal,
                    Colors.orange,  // 修改颜色
                  ),
                
                // 5. 空状态提示
                if (_accounts.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(40.0),
                      child: Column(
                        children: [
                          const Icon(Icons.account_balance_wallet, size: 60, color: Colors.grey),
                          const SizedBox(height: 16),
                          const Text(
                            '还没有任何账户',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '点击下方"+"按钮添加第一个账户',
                            style: TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: _addNewAccount,
                            child: const Text('添加账户'),
                          ),
                        ],
                      ),
                    ),
                  ),
                
                const SizedBox(height: 40),
              ],
            ),
          ),
    floatingActionButton: FloatingActionButton(
      onPressed: _addNewAccount,
      child: const Icon(Icons.add),
    ),
  );
}

}
