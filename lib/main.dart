import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ink = Color(0xFF23313D);
const _paper = Color(0xFFFFFBF3);
const _sage = Color(0xFF72866F);
const _coral = Color(0xFFCD765C);
const _gold = Color(0xFFC99A43);
const _mist = Color(0xFFE8E4D9);

final _yen = NumberFormat.currency(
  locale: 'ja_JP',
  symbol: '¥',
  decimalDigits: 0,
);
final _monthFormat = DateFormat('yyyy年 M月', 'ja_JP');
final _dateFormat = DateFormat('M月d日 (E)', 'ja_JP');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await HouseholdStore.open();
  runApp(KurashiApp(store: store));
}

class KurashiApp extends StatelessWidget {
  const KurashiApp({super.key, required this.store});
  final HouseholdStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'くらし帳',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _sage,
          brightness: Brightness.light,
          surface: _paper,
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: _ink,
          displayColor: _ink,
          fontFamily: 'sans-serif',
        ),
      ),
      home: HomeShell(store: store),
    );
  }
}

class Expense {
  const Expense({
    required this.id,
    required this.merchant,
    required this.amount,
    required this.date,
    required this.category,
    required this.note,
    required this.payment,
    required this.source,
    this.imagePath,
  });

  final String id;
  final String merchant;
  final int amount;
  final DateTime date;
  final String category;
  final String note;
  final String payment;
  final String source;
  final String? imagePath;

  Map<String, dynamic> toJson() => {
    'id': id,
    'merchant': merchant,
    'amount': amount,
    'date': date.toIso8601String(),
    'category': category,
    'note': note,
    'payment': payment,
    'source': source,
    'imagePath': imagePath,
  };

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    id: json['id'] as String,
    merchant: json['merchant'] as String,
    amount: json['amount'] as int,
    date: DateTime.parse(json['date'] as String),
    category: json['category'] as String,
    note: json['note'] as String? ?? '',
    payment: json['payment'] as String? ?? '現金',
    source: json['source'] as String? ?? 'manual',
    imagePath: json['imagePath'] as String?,
  );
}

class BudgetCategory {
  const BudgetCategory(this.id, this.name, this.icon, this.color);
  final String id;
  final String name;
  final IconData icon;
  final Color color;
}

const categories = [
  BudgetCategory('food', '食費', Icons.restaurant_rounded, Color(0xFFCD765C)),
  BudgetCategory('daily', '日用品', Icons.shopping_bag_rounded, Color(0xFF72866F)),
  BudgetCategory(
    'transport',
    '交通費',
    Icons.directions_train_rounded,
    Color(0xFF7192A8),
  ),
  BudgetCategory(
    'leisure',
    '楽しみ',
    Icons.local_florist_rounded,
    Color(0xFFC99A43),
  ),
  BudgetCategory('fixed', '固定費', Icons.home_rounded, Color(0xFF8A7A9C)),
  BudgetCategory('other', 'その他', Icons.more_horiz_rounded, Color(0xFF9D998C)),
];

BudgetCategory categoryOf(String id) => categories.firstWhere(
  (category) => category.id == id,
  orElse: () => categories.last,
);

class HouseholdStore extends ChangeNotifier {
  HouseholdStore._(this._prefs, this.expenses, this.budget);
  final SharedPreferences _prefs;
  List<Expense> expenses;
  int budget;

  static Future<HouseholdStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('expenses_v1');
    final expenses = raw == null
        ? <Expense>[]
        : (jsonDecode(raw) as List<dynamic>)
              .map((value) => Expense.fromJson(value as Map<String, dynamic>))
              .toList();
    return HouseholdStore._(
      prefs,
      expenses,
      prefs.getInt('monthly_budget_v1') ?? 100000,
    );
  }

  Future<void> upsert(Expense value) async {
    expenses = [...expenses.where((expense) => expense.id != value.id), value]
      ..sort((a, b) => b.date.compareTo(a.date));
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    expenses = expenses.where((expense) => expense.id != id).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> setBudget(int value) async {
    budget = value;
    await _prefs.setInt('monthly_budget_v1', value);
    notifyListeners();
  }

  Future<void> _persist() => _prefs.setString(
    'expenses_v1',
    jsonEncode(expenses.map((expense) => expense.toJson()).toList()),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.store});
  final HouseholdStore store;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _tab = 0;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() => mounted ? setState(() {}) : null;

  List<Expense> get _monthly => widget.store.expenses
      .where(
        (expense) =>
            expense.date.year == _month.year &&
            expense.date.month == _month.month,
      )
      .toList();

  Future<void> _openAdd({String? imagePath, bool fromScan = false}) async {
    final saved = await Navigator.of(context).push<Expense>(
      MaterialPageRoute(
        builder: (_) => ExpenseEditor(imagePath: imagePath, fromScan: fromScan),
      ),
    );
    if (saved != null) await widget.store.upsert(saved);
  }

  Future<void> _pickPhoto(ImageSource source) async {
    Navigator.pop(context);
    final photo = await ImagePicker().pickImage(
      source: source,
      imageQuality: 86,
      maxWidth: 2048,
    );
    if (!mounted || photo == null) return;
    await _openAdd(imagePath: photo.path, fromScan: true);
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        decoration: const BoxDecoration(
          color: _paper,
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: _mist,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '支出を記録する',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              '写真は端末内にだけ保存されます',
              style: TextStyle(color: Color(0xFF707A7E)),
            ),
            const SizedBox(height: 18),
            _AddOption(
              icon: Icons.camera_alt_rounded,
              title: 'カメラで撮る',
              subtitle: 'レシートを添えて手入力へ',
              onTap: () => _pickPhoto(ImageSource.camera),
            ),
            _AddOption(
              icon: Icons.photo_library_rounded,
              title: '写真を選ぶ',
              subtitle: '購入画面・請求画面にも対応',
              onTap: () => _pickPhoto(ImageSource.gallery),
            ),
            _AddOption(
              icon: Icons.edit_note_rounded,
              title: '手動で入力',
              subtitle: 'いまの支出をすぐ記録',
              onTap: () {
                Navigator.pop(context);
                _openAdd();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(
        month: _month,
        expenses: _monthly,
        budget: widget.store.budget,
        onPrevious: () =>
            setState(() => _month = DateTime(_month.year, _month.month - 1)),
        onNext: () =>
            setState(() => _month = DateTime(_month.year, _month.month + 1)),
        onExpense: _showDetail,
        onSeeHistory: () => setState(() => _tab = 1),
        onSettings: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BudgetSettingsPage(
              budget: widget.store.budget,
              onSave: widget.store.setBudget,
            ),
          ),
        ),
        onCategory: (categoryId) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CategoryDetailPage(
              month: _month,
              category: categoryOf(categoryId),
              expenses: _monthly
                  .where((expense) => expense.category == categoryId)
                  .toList(),
              onExpense: _showDetail,
            ),
          ),
        ),
      ),
      HistoryPage(expenses: widget.store.expenses, onExpense: _showDetail),
      ExportPage(
        month: _month,
        expenses: _monthly,
        budget: widget.store.budget,
      ),
    ];
    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      floatingActionButton: _tab == 2
          ? null
          : FloatingActionButton.extended(
              onPressed: _showAddSheet,
              elevation: 0,
              backgroundColor: _ink,
              foregroundColor: _paper,
              icon: const Icon(Icons.add_rounded),
              label: const Text(
                '記録する',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
      bottomNavigationBar: NavigationBar(
        height: 74,
        backgroundColor: const Color(0xFFFFFDF8),
        indicatorColor: const Color(0xFFE2E8D9),
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'くらし',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: '履歴',
          ),
          NavigationDestination(
            icon: Icon(Icons.ios_share_outlined),
            selectedIcon: Icon(Icons.ios_share_rounded),
            label: '書き出し',
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(Expense expense) async {
    final changed = await Navigator.of(context).push<_ExpenseAction>(
      MaterialPageRoute(builder: (_) => ExpenseDetail(expense: expense)),
    );
    if (!mounted || changed == null) return;
    if (changed.delete) {
      await widget.store.remove(expense.id);
    } else if (changed.expense != null) {
      await widget.store.upsert(changed.expense!);
    }
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.month,
    required this.expenses,
    required this.budget,
    required this.onPrevious,
    required this.onNext,
    required this.onExpense,
    required this.onSeeHistory,
    required this.onSettings,
    required this.onCategory,
  });
  final DateTime month;
  final List<Expense> expenses;
  final int budget;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<Expense> onExpense;
  final VoidCallback onSeeHistory;
  final VoidCallback onSettings;
  final ValueChanged<String> onCategory;

  @override
  Widget build(BuildContext context) {
    final total = expenses.fold<int>(0, (sum, expense) => sum + expense.amount);
    final remaining = budget - total;
    final breakdown = <String, int>{};
    for (final expense in expenses) {
      breakdown.update(
        expense.category,
        (amount) => amount + expense.amount,
        ifAbsent: () => expense.amount,
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: const BoxDecoration(
                          color: _ink,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.spa_rounded,
                          color: _paper,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'くらし帳',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              letterSpacing: .5,
                            ),
                          ),
                          Text(
                            'お金と、心地よく暮らす。',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF677176),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: onSettings,
                        icon: const Icon(Icons.tune_rounded),
                        tooltip: '設定',
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: onPrevious,
                        icon: const Icon(Icons.chevron_left_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFF0EEE7),
                        ),
                      ),
                      Text(
                        _monthFormat.format(month),
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      IconButton(
                        onPressed: onNext,
                        icon: const Icon(Icons.chevron_right_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFF0EEE7),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SummaryCard(
                    total: total,
                    budget: budget,
                    remaining: remaining,
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    '今月の景色',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  _CategoryCard(
                    total: total,
                    breakdown: breakdown,
                    onCategory: onCategory,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      const Text(
                        '最近の記録',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onSeeHistory,
                        child: const Text('すべて見る'),
                      ),
                    ],
                  ),
                  if (expenses.isEmpty)
                    _EmptyLedger(onAdd: () => Navigator.of(context).maybePop())
                  else ...[
                    ...expenses
                        .take(5)
                        .map(
                          (expense) => _ExpenseTile(
                            expense: expense,
                            onTap: () => onExpense(expense),
                          ),
                        ),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Icon(icon, size: 18, color: _sage),
        const SizedBox(width: 9),
        Text(label),
      ],
    ),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.total,
    required this.budget,
    required this.remaining,
  });
  final int total;
  final int budget;
  final int remaining;
  @override
  Widget build(BuildContext context) {
    final progress = budget == 0 ? 0.0 : (total / budget).clamp(0.0, 1.0);
    return Container(
      height: 215,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF3EEDC),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: .37,
              child: Image.asset(
                'assets/images/ledger_garden.png',
                fit: BoxFit.cover,
                alignment: Alignment.bottomRight,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '今月使ったお金',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF5A625F),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _yen.format(total),
                  style: const TextStyle(
                    fontSize: 36,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '今月の予算',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF5A625F),
                            ),
                          ),
                          Text(
                            _yen.format(budget),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 32,
                      color: const Color(0x33576150),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'のこり',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF5A625F),
                            ),
                          ),
                          Text(
                            _yen.format(remaining),
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: remaining < 0 ? _coral : _ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 7,
                    backgroundColor: const Color(0x44FFFFFF),
                    valueColor: AlwaysStoppedAnimation(
                      progress > .9 ? _coral : _sage,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.total,
    required this.breakdown,
    required this.onCategory,
  });
  final int total;
  final Map<String, int> breakdown;
  final ValueChanged<String> onCategory;
  @override
  Widget build(BuildContext context) {
    if (total == 0) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: _cardDecoration,
        child: const Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: _gold),
            SizedBox(width: 12),
            Expanded(child: Text('記録をはじめると、ここにお金の流れが育ちます。')),
          ],
        ),
      );
    }
    final entries = breakdown.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration,
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 128,
                height: 128,
                child: CustomPaint(painter: PieChartPainter(entries, total)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: entries.take(4).map((entry) {
                    final category = categoryOf(entry.key);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: category.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              category.name,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Text(
                            '${(entry.value / total * 100).round()}%',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          const Divider(height: 27, color: _mist),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: entries.take(5).map((entry) {
              final category = categoryOf(entry.key);
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onCategory(entry.key),
                  borderRadius: BorderRadius.circular(99),
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: category.color.withValues(alpha: .11),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '${category.name} ${_yen.format(entry.value)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class CategoryDetailPage extends StatelessWidget {
  const CategoryDetailPage({
    super.key,
    required this.month,
    required this.category,
    required this.expenses,
    required this.onExpense,
  });

  final DateTime month;
  final BudgetCategory category;
  final List<Expense> expenses;
  final ValueChanged<Expense> onExpense;

  @override
  Widget build(BuildContext context) {
    final total = expenses.fold<int>(0, (sum, expense) => sum + expense.amount);
    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(backgroundColor: _paper, elevation: 0),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor: category.color.withValues(alpha: .14),
                  foregroundColor: category.color,
                  child: Icon(category.icon),
                ),
                const SizedBox(height: 15),
                Text(
                  '${_monthFormat.format(month)}の${category.name}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${expenses.length}件の記録 ・ ${_yen.format(total)}',
                  style: const TextStyle(color: Color(0xFF6D777B)),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: expenses.isEmpty
                      ? const Center(child: Text('このカテゴリの記録はありません'))
                      : ListView(
                          children: expenses
                              .map(
                                (expense) => _ExpenseTile(
                                  expense: expense,
                                  onTap: () => onExpense(expense),
                                ),
                              )
                              .toList(),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BudgetSettingsPage extends StatefulWidget {
  const BudgetSettingsPage({
    super.key,
    required this.budget,
    required this.onSave,
  });

  final int budget;
  final Future<void> Function(int) onSave;

  @override
  State<BudgetSettingsPage> createState() => _BudgetSettingsPageState();
}

class _BudgetSettingsPageState extends State<BudgetSettingsPage> {
  late final TextEditingController _budget;

  @override
  void initState() {
    super.initState();
    _budget = TextEditingController(text: widget.budget.toString());
  }

  @override
  void dispose() {
    _budget.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = int.tryParse(_budget.text.replaceAll(',', ''));
    if (value == null || value < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('予算を0円以上で入力してください')));
      return;
    }
    await widget.onSave(value);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(
      backgroundColor: _paper,
      title: const Text('設定', style: TextStyle(fontWeight: FontWeight.w800)),
      actions: [TextButton(onPressed: _save, child: const Text('保存'))],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '月の予算',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text('使いすぎを責めず、目安として置いておけます。'),
            const SizedBox(height: 16),
            TextField(
              controller: _budget,
              keyboardType: TextInputType.number,
              decoration: _inputDecoration(prefix: '¥', hint: '例）100000'),
            ),
            const SizedBox(height: 28),
            const Text(
              'プライバシー',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: _cardDecoration,
              child: const Column(
                children: [
                  _InfoLine(Icons.lock_outline_rounded, '記録はこの端末に保存'),
                  _InfoLine(Icons.image_outlined, '添付画像は外部へ送信しない'),
                  _InfoLine(Icons.auto_awesome_outlined, '端末内AIによる解析は準備中'),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

final _cardDecoration = BoxDecoration(
  color: const Color(0xFFFFFDF8),
  borderRadius: BorderRadius.circular(24),
  border: Border.all(color: const Color(0xFFE9E4D9)),
);

class PieChartPainter extends CustomPainter {
  PieChartPainter(this.entries, this.total);
  final List<MapEntry<String, int>> entries;
  final int total;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    var start = -pi / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 17
      ..strokeCap = StrokeCap.round;
    for (final entry in entries) {
      final sweep = entry.value / total * 2 * pi;
      paint.color = categoryOf(entry.key).color;
      canvas.drawArc(
        rect.deflate(10),
        start,
        max(sweep - .045, .01),
        false,
        paint,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant PieChartPainter oldDelegate) => true;
}

class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense, required this.onTap});
  final Expense expense;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final category = categoryOf(expense.category);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
            child: Row(
              children: [
                Container(
                  width: 43,
                  height: 43,
                  decoration: BoxDecoration(
                    color: category.color.withValues(alpha: .12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(category.icon, color: category.color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        expense.merchant.isEmpty ? '名前のない記録' : expense.merchant,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_dateFormat.format(expense.date)} ・ ${category.name}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF737B7E),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _yen.format(expense.amount),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyLedger extends StatelessWidget {
  const _EmptyLedger({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: _cardDecoration,
    child: const Row(
      children: [
        Icon(Icons.menu_book_rounded, color: _sage),
        SizedBox(width: 12),
        Expanded(child: Text('まだ記録がありません。右下の「記録する」から、最初の一歩を残しましょう。')),
      ],
    ),
  );
}

class _AddOption extends StatelessWidget {
  const _AddOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFE6EBDD),
        foregroundColor: _sage,
        child: Icon(icon),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(subtitle),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.expenses,
    required this.onExpense,
  });
  final List<Expense> expenses;
  final ValueChanged<Expense> onExpense;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _query = '';
  String _filter = 'all';
  @override
  Widget build(BuildContext context) {
    final items = widget.expenses
        .where(
          (expense) =>
              (_filter == 'all' || expense.category == _filter) &&
              ('${expense.merchant} ${expense.note}'.toLowerCase().contains(
                _query.toLowerCase(),
              )),
        )
        .toList();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 110),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '記録をふりかえる',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              const Text(
                '小さな選択を、やさしく見渡す。',
                style: TextStyle(color: Color(0xFF6D777B)),
              ),
              const SizedBox(height: 20),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'お店・メモを検索',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: const Color(0xFFFFFDF8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: const BorderSide(color: _mist),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: const BorderSide(color: _mist),
                  ),
                ),
              ),
              const SizedBox(height: 13),
              SizedBox(
                height: 37,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    FilterChip(
                      label: const Text('すべて'),
                      selected: _filter == 'all',
                      onSelected: (_) => setState(() => _filter = 'all'),
                    ),
                    ...categories.map(
                      (category) => Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: FilterChip(
                          label: Text(category.name),
                          selected: _filter == category.id,
                          onSelected: (_) =>
                              setState(() => _filter = category.id),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('条件に合う記録はありません'))
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (_, index) => _ExpenseTile(
                          expense: items[index],
                          onTap: () => widget.onExpense(items[index]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExportPage extends StatelessWidget {
  const ExportPage({
    super.key,
    required this.month,
    required this.expenses,
    required this.budget,
  });
  final DateTime month;
  final List<Expense> expenses;
  final int budget;
  String get _markdown {
    final total = expenses.fold<int>(0, (sum, expense) => sum + expense.amount);
    final rows = expenses
        .map(
          (e) =>
              '| ${DateFormat('M/d').format(e.date)} | ${e.merchant.isEmpty ? '—' : e.merchant} | ${categoryOf(e.category).name} | ${_yen.format(e.amount)} |',
        )
        .join('\n');
    return '# ${DateFormat('yyyy年M月').format(month)} のくらし帳\n\n- 支出合計: ${_yen.format(total)}\n- 月の予算: ${_yen.format(budget)}\n- のこり: ${_yen.format(budget - total)}\n\n## 記録\n\n| 日付 | お店・内容 | カテゴリ | 金額 |\n| --- | --- | --- | ---: |\n$rows\n';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 35),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '今月を書き出す',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              Text(
                '${_monthFormat.format(month)}の記録を、あとから読める形に。',
                style: const TextStyle(color: Color(0xFF6D777B)),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: _cardDecoration,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.code_rounded, color: _sage),
                        SizedBox(width: 9),
                        Text(
                          'Markdown',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Spacer(),
                        Chip(label: Text('詳細版')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '月の合計、予算、登録した支出を表形式でまとめます。画像のパスや個人情報は含めません。',
                      style: TextStyle(height: 1.55),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _markdown));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Markdownをクリップボードにコピーしました'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Markdownをコピー'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _ink,
                        foregroundColor: _paper,
                        minimumSize: const Size.fromHeight(50),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'プレビュー',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 9),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F0E8),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _markdown,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExpenseEditor extends StatefulWidget {
  const ExpenseEditor({
    super.key,
    this.initial,
    this.imagePath,
    this.fromScan = false,
  });
  final Expense? initial;
  final String? imagePath;
  final bool fromScan;
  @override
  State<ExpenseEditor> createState() => _ExpenseEditorState();
}

class _ExpenseEditorState extends State<ExpenseEditor> {
  late final TextEditingController _merchant;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late DateTime _date;
  late String _category;
  late String _payment;
  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    _merchant = TextEditingController(text: value?.merchant ?? '');
    _amount = TextEditingController(
      text: value == null ? '' : value.amount.toString(),
    );
    _note = TextEditingController(text: value?.note ?? '');
    _date = value?.date ?? DateTime.now();
    _category = value?.category ?? 'food';
    _payment = value?.payment ?? '現金';
  }

  @override
  void dispose() {
    _merchant.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final amount = int.tryParse(_amount.text.replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('金額を1円以上で入力してください')));
      return;
    }
    Navigator.pop(
      context,
      Expense(
        id: widget.initial?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
        merchant: _merchant.text.trim(),
        amount: amount,
        date: _date,
        category: _category,
        note: _note.text.trim(),
        payment: _payment,
        source: widget.fromScan ? 'image' : 'manual',
        imagePath: widget.imagePath ?? widget.initial?.imagePath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _paper,
        title: Text(
          widget.initial == null ? '支出を記録' : '記録を編集',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              '保存',
              style: TextStyle(fontWeight: FontWeight.w800, color: _sage),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                if (widget.fromScan)
                  Container(
                    margin: const EdgeInsets.only(bottom: 18),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9EFE3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.privacy_tip_outlined, color: _sage),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '画像を添えました。内容を確認してから保存してください。画像は外部送信しません。',
                            style: TextStyle(fontSize: 13, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                _field('お店・サービス', _merchant, hint: '例）八百屋さん'),
                const SizedBox(height: 16),
                _field(
                  '金額',
                  _amount,
                  hint: '例）1280',
                  keyboard: TextInputType.number,
                  prefix: '¥',
                ),
                const SizedBox(height: 17),
                const Text(
                  'カテゴリ',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: categories
                      .map(
                        (category) => ChoiceChip(
                          avatar: Icon(
                            category.icon,
                            size: 16,
                            color: _category == category.id
                                ? _paper
                                : category.color,
                          ),
                          label: Text(category.name),
                          selected: _category == category.id,
                          selectedColor: category.color,
                          labelStyle: TextStyle(
                            color: _category == category.id ? _paper : _ink,
                            fontWeight: FontWeight.w700,
                          ),
                          onSelected: (_) =>
                              setState(() => _category = category.id),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'いつ使った？',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(_dateFormat.format(_date)),
                  trailing: const Icon(Icons.calendar_today_rounded, size: 20),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  '支払い方法',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _payment,
                  items: const ['現金', 'クレジットカード', 'PayPay', '交通系IC', 'その他']
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _payment = value!),
                  decoration: _inputDecoration(),
                ),
                const SizedBox(height: 16),
                _field('メモ（任意）', _note, hint: '気づきや、誰と食べたかなど'),
                const SizedBox(height: 26),
                FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _ink,
                    foregroundColor: _paper,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text(
                    'この内容で記録する',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboard,
    String? prefix,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: keyboard,
        decoration: _inputDecoration(hint: hint, prefix: prefix),
      ),
    ],
  );
}

InputDecoration _inputDecoration({String? hint, String? prefix}) =>
    InputDecoration(
      hintText: hint,
      prefixText: prefix,
      filled: true,
      fillColor: const Color(0xFFFFFDF8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _mist),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _mist),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _sage, width: 1.5),
      ),
    );

class _ExpenseAction {
  const _ExpenseAction({this.expense, this.delete = false});
  final Expense? expense;
  final bool delete;
}

class ExpenseDetail extends StatelessWidget {
  const ExpenseDetail({super.key, required this.expense});
  final Expense expense;
  @override
  Widget build(BuildContext context) {
    final category = categoryOf(expense.category);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _paper,
        title: const Text(
          '記録の詳細',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final edited = await Navigator.of(context).push<Expense>(
                MaterialPageRoute(
                  builder: (_) => ExpenseEditor(initial: expense),
                ),
              );
              if (context.mounted && edited != null) {
                Navigator.pop(context, _ExpenseAction(expense: edited));
              }
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 55,
                  height: 55,
                  decoration: BoxDecoration(
                    color: category.color.withValues(alpha: .13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(category.icon, color: category.color),
                ),
                const SizedBox(height: 22),
                Text(
                  expense.merchant.isEmpty ? '名前のない記録' : expense.merchant,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _dateFormat.format(expense.date),
                  style: const TextStyle(color: Color(0xFF6C7578)),
                ),
                const SizedBox(height: 18),
                Text(
                  _yen.format(expense.amount),
                  style: const TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: _cardDecoration,
                  child: Column(
                    children: [
                      _detailRow('カテゴリ', category.name),
                      _detailRow('支払い方法', expense.payment),
                      if (expense.note.isNotEmpty)
                        _detailRow('メモ', expense.note),
                      _detailRow(
                        '記録方法',
                        expense.source == 'image' ? '画像を添えて記録' : '手動入力',
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('この記録を削除しますか？'),
                        content: const Text('削除後は元に戻せません。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('キャンセル'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(
                              foregroundColor: _coral,
                            ),
                            child: const Text('削除する'),
                          ),
                        ],
                      ),
                    );
                    if (context.mounted && confirm == true) {
                      Navigator.pop(
                        context,
                        const _ExpenseAction(delete: true),
                      );
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('この記録を削除'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _coral,
                    minimumSize: const Size.fromHeight(50),
                    side: const BorderSide(color: Color(0xFFDFA89A)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 94,
          child: Text(key, style: const TextStyle(color: Color(0xFF70777A))),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}
