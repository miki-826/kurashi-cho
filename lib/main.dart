import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import 'database.dart';

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
  await initializeDateFormatting('ja_JP');
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
    this.items = const [],
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
  final List<ExpenseItem> items;

  int amountForCategory(String categoryId) {
    if (items.isEmpty) return category == categoryId ? amount : 0;
    final itemTotal = items.fold<int>(0, (sum, item) => sum + item.amount);
    final categorized = items
        .where((item) => item.category == categoryId)
        .fold(0, (sum, item) => sum + item.amount);
    final difference = amount - itemTotal;
    return categorized + (category == categoryId ? difference : 0);
  }

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
    'items': items.map((item) => item.toJson()).toList(),
  };

  factory Expense.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    final items = rawItems
        .map((item) => ExpenseItem.fromJson(item as Map<String, dynamic>))
        .toList();
    if (items.isEmpty) {
      items.add(
        ExpenseItem(
          id: '${json['id']}-0',
          name: (json['merchant'] as String?)?.isNotEmpty == true
              ? json['merchant'] as String
              : '支出',
          quantity: 1,
          amount: json['amount'] as int,
          category: json['category'] as String? ?? 'other',
        ),
      );
    }
    return Expense(
      id: json['id'] as String,
      merchant: json['merchant'] as String? ?? '',
      amount: json['amount'] as int,
      date: DateTime.parse(json['date'] as String),
      category: json['category'] as String? ?? 'other',
      note: json['note'] as String? ?? '',
      payment: json['payment'] as String? ?? '現金',
      source: json['source'] as String? ?? 'manual',
      imagePath: json['imagePath'] as String?,
      items: items,
    );
  }
}

class ExpenseItem {
  const ExpenseItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.amount,
    required this.category,
  });

  final String id;
  final String name;
  final int quantity;
  final int amount;
  final String category;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'quantity': quantity,
    'amount': amount,
    'category': category,
  };

  factory ExpenseItem.fromJson(Map<String, dynamic> json) => ExpenseItem(
    id: json['id'] as String,
    name: json['name'] as String? ?? '支出',
    quantity: json['quantity'] as int? ?? 1,
    amount: json['amount'] as int? ?? 0,
    category: json['category'] as String? ?? 'other',
  );
}

class BudgetCategory {
  const BudgetCategory(this.id, this.name, this.icon, this.color);
  final String id;
  final String name;
  final IconData icon;
  final Color color;
}

class ReceiptDraft {
  const ReceiptDraft({
    required this.imagePath,
    this.merchant,
    this.amount,
    this.date,
    this.category = 'other',
    this.rawText = '',
    this.payment,
    this.items = const [],
    this.confidence,
    this.warnings = const [],
    this.usedAi = false,
  });

  final String imagePath;
  final String? merchant;
  final int? amount;
  final DateTime? date;
  final String category;
  final String rawText;
  final String? payment;
  final List<ExpenseItem> items;
  final double? confidence;
  final List<String> warnings;
  final bool usedAi;

  ReceiptDraft withNanoResponse(String response) {
    var source = response.trim();
    if (source.startsWith('```')) {
      source = source
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
    }
    final value = jsonDecode(source) as Map<String, dynamic>;
    final rawCategories = categories.map((category) => category.id).toSet();
    final rawItems = value['items'] as List<dynamic>? ?? const [];
    final parsedItems = <ExpenseItem>[];
    for (var index = 0; index < rawItems.length; index++) {
      final item = rawItems[index] as Map<String, dynamic>;
      final amount = (item['amount'] as num?)?.toInt() ?? 0;
      if (amount < 0) continue;
      final rawCategory = item['categoryCode'] as String? ?? 'other';
      parsedItems.add(
        ExpenseItem(
          id: '${DateTime.now().microsecondsSinceEpoch}-$index',
          name: (item['name'] as String?)?.trim().isNotEmpty == true
              ? (item['name'] as String).trim()
              : '不明な商品',
          quantity: max(1, (item['quantity'] as num?)?.toInt() ?? 1),
          amount: amount,
          category: rawCategories.contains(rawCategory) ? rawCategory : 'other',
        ),
      );
    }
    DateTime? parsedDate;
    final purchasedAt = value['purchasedAt'] as String?;
    if (purchasedAt != null) parsedDate = DateTime.tryParse(purchasedAt);
    final total = (value['totalAmount'] as num?)?.toInt();
    final confidenceValue = (value['confidence'] as num?)?.toDouble();
    final aiWarnings = (value['warnings'] as List<dynamic>? ?? const [])
        .map((warning) => warning.toString())
        .toList();
    return ReceiptDraft(
      imagePath: imagePath,
      merchant: (value['merchant'] as String?)?.trim().isNotEmpty == true
          ? (value['merchant'] as String).trim()
          : merchant,
      amount: total != null && total > 0 ? total : amount,
      date: parsedDate ?? date,
      category: parsedItems.isNotEmpty ? parsedItems.first.category : category,
      rawText: rawText,
      payment: (value['paymentMethod'] as String?)?.trim(),
      items: parsedItems,
      confidence: confidenceValue?.clamp(0, 1),
      warnings: aiWarnings,
      usedAi: true,
    );
  }

  factory ReceiptDraft.fromRecognizedText(String imagePath, String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    String? merchant;
    for (final line in lines.take(8)) {
      if (!RegExp(r'\d{2,}').hasMatch(line) &&
          !line.toUpperCase().contains('TEL') &&
          !line.contains('レシート') &&
          line.length >= 2) {
        merchant = line;
        break;
      }
    }
    final totalPattern = RegExp(
      r'(?:合\s*計|お買上|請求額|ご利用額|支払額)[^0-9]{0,12}([0-9][0-9,]{1,})',
      caseSensitive: false,
    );
    final matches = totalPattern.allMatches(rawText).toList();
    int? amount = matches.isEmpty
        ? null
        : int.tryParse(matches.last.group(1)!.replaceAll(',', ''));
    if (amount == null) {
      final yenMatches = RegExp(r'[¥￥]\s*([0-9][0-9,]*)')
          .allMatches(rawText)
          .map((match) => int.tryParse(match.group(1)!.replaceAll(',', '')))
          .whereType<int>()
          .toList();
      if (yenMatches.isNotEmpty) amount = yenMatches.reduce(max);
    }
    final dateMatch = RegExp(
      r'(20\d{2})[./年-]\s*(\d{1,2})[./月-]\s*(\d{1,2})',
    ).firstMatch(rawText);
    DateTime? date;
    if (dateMatch != null) {
      date = DateTime(
        int.parse(dateMatch.group(1)!),
        int.parse(dateMatch.group(2)!),
        int.parse(dateMatch.group(3)!),
      );
    }
    return ReceiptDraft(
      imagePath: imagePath,
      merchant: merchant,
      amount: amount,
      date: date,
      category: _categoryFromText(rawText),
      rawText: rawText,
    );
  }

  static String _categoryFromText(String text) {
    if (RegExp(r'スーパー|コンビニ|食品|弁当|飲食|カフェ|レストラン').hasMatch(text)) return 'food';
    if (RegExp(r'電車|バス|タクシー|交通').hasMatch(text)) return 'transport';
    if (RegExp(r'ドラッグ|日用品|洗剤|ティッシュ').hasMatch(text)) return 'daily';
    if (RegExp(r'映画|ゲーム|書籍|チケット').hasMatch(text)) return 'leisure';
    return 'other';
  }
}

class NanoGateway {
  static const _channel = MethodChannel('com.miki.householdai/gemini_nano');

  static Future<String> checkStatus() async {
    if (!Platform.isAndroid) return 'UNAVAILABLE';
    try {
      return await _channel.invokeMethod<String>('checkStatus') ?? 'ERROR';
    } on PlatformException {
      return 'ERROR';
    } on MissingPluginException {
      return 'UNAVAILABLE';
    }
  }

  static Future<String> downloadModel() async {
    if (!Platform.isAndroid) return 'UNAVAILABLE';
    try {
      return await _channel.invokeMethod<String>('downloadModel') ?? 'ERROR';
    } on PlatformException {
      return 'ERROR';
    }
  }

  static Future<String> analyze({
    required String imagePath,
    required String ocrText,
  }) async {
    final categoryList = categories
        .map((category) => '${category.id}: ${category.name}')
        .join(', ');
    final response = await _channel
        .invokeMethod<String>('analyzeReceipt', {
          'imagePath': imagePath,
          'ocrText': ocrText,
          'categories': categoryList,
          'currentDateTime': DateTime.now().toIso8601String(),
        })
        .timeout(const Duration(seconds: 120));
    if (response == null || response.trim().isEmpty) {
      throw const FormatException('Gemini Nano returned an empty response');
    }
    return response;
  }
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
  HouseholdStore._(this._prefs, this._database, this.expenses, this._budgets);
  final SharedPreferences _prefs;
  final AppDatabase _database;
  List<Expense> expenses;
  Map<String, int> _budgets;

  String _monthKey(DateTime month) =>
      '${month.year}-${month.month.toString().padLeft(2, '0')}';

  int budgetFor(DateTime month) => _budgets[_monthKey(month)] ?? 100000;

  static Future<HouseholdStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    final database = AppDatabase();
    final raw = prefs.getString('expenses_v1');
    var expenses = (await database.loadExpenses())
        .map(Expense.fromJson)
        .toList();
    if (expenses.isEmpty && raw != null) {
      expenses = (jsonDecode(raw) as List<dynamic>)
          .map((value) => Expense.fromJson(value as Map<String, dynamic>))
          .toList();
      for (final expense in expenses) {
        await database.replaceExpense(expense.toJson());
      }
    }
    final budgets = await database.loadBudgets();
    final currentMonth = DateTime.now();
    final currentKey =
        '${currentMonth.year}-${currentMonth.month.toString().padLeft(2, '0')}';
    if (!budgets.containsKey(currentKey)) {
      final migrated =
          budgets['default'] ?? prefs.getInt('monthly_budget_v1') ?? 100000;
      budgets[currentKey] = migrated;
      await database.saveBudget(currentKey, migrated);
    }
    return HouseholdStore._(prefs, database, expenses, budgets);
  }

  Future<void> upsert(Expense value) async {
    final saved = await _copyImageToAppStorage(value);
    expenses = [...expenses.where((expense) => expense.id != saved.id), saved]
      ..sort((a, b) => b.date.compareTo(a.date));
    await _database.replaceExpense(saved.toJson());
    notifyListeners();
  }

  Future<void> remove(String id) async {
    final removed = expenses.where((expense) => expense.id == id).firstOrNull;
    expenses = expenses.where((expense) => expense.id != id).toList();
    await _database.removeExpense(id);
    final imagePath = removed?.imagePath;
    if (imagePath != null &&
        !expenses.any((expense) => expense.imagePath == imagePath)) {
      final image = File(imagePath);
      if (await image.exists()) {
        try {
          await image.delete();
        } on FileSystemException {
          // The financial record is deleted even if Android still holds the file.
        }
      }
    }
    notifyListeners();
  }

  Future<void> setBudget(DateTime month, int value) async {
    final key = _monthKey(month);
    _budgets = {..._budgets, key: value};
    await _prefs.setInt('monthly_budget_v1', value);
    await _database.saveBudget(key, value);
    notifyListeners();
  }

  Future<Expense> _copyImageToAppStorage(Expense value) async {
    final sourcePath = value.imagePath;
    if (sourcePath == null || sourcePath.isEmpty) return value;
    final source = File(sourcePath);
    if (!await source.exists()) return value;
    final documents = await getApplicationDocumentsDirectory();
    final receiptDirectory = Directory(
      '${documents.path}${Platform.pathSeparator}receipts',
    );
    if (source.path.startsWith(receiptDirectory.path)) return value;
    await receiptDirectory.create(recursive: true);
    final match = RegExp(
      r'\.(jpe?g|png|webp)$',
      caseSensitive: false,
    ).firstMatch(source.path);
    final extension = match?.group(0) ?? '.jpg';
    final copied = await source.copy(
      '${receiptDirectory.path}${Platform.pathSeparator}${value.id}$extension',
    );
    return Expense(
      id: value.id,
      merchant: value.merchant,
      amount: value.amount,
      date: value.date,
      category: value.category,
      note: value.note,
      payment: value.payment,
      source: value.source,
      imagePath: copied.path,
      items: value.items,
    );
  }
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

  Future<void> _openAdd({
    String? imagePath,
    bool fromScan = false,
    ReceiptDraft? draft,
  }) async {
    final saved = await Navigator.of(context).push<Expense>(
      MaterialPageRoute(
        builder: (_) => ExpenseEditor(
          imagePath: imagePath,
          fromScan: fromScan,
          draft: draft,
        ),
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
    final draft = await Navigator.of(context).push<ReceiptDraft>(
      MaterialPageRoute(
        builder: (_) => ReceiptPreviewPage(imagePath: photo.path),
      ),
    );
    if (!mounted || draft == null) return;
    await _openAdd(imagePath: draft.imagePath, fromScan: true, draft: draft);
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
        budget: widget.store.budgetFor(_month),
        onPrevious: () =>
            setState(() => _month = DateTime(_month.year, _month.month - 1)),
        onNext: () =>
            setState(() => _month = DateTime(_month.year, _month.month + 1)),
        onExpense: _showDetail,
        onSeeHistory: () => setState(() => _tab = 1),
        onSettings: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BudgetSettingsPage(
              budget: widget.store.budgetFor(_month),
              onSave: (value) => widget.store.setBudget(_month, value),
            ),
          ),
        ),
        onCategory: (categoryId) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CategoryDetailPage(
              month: _month,
              category: categoryOf(categoryId),
              expenses: _monthly
                  .where(
                    (expense) => expense.amountForCategory(categoryId) != 0,
                  )
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
        budget: widget.store.budgetFor(_month),
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
      for (final category in categories) {
        final amount = expense.amountForCategory(category.id);
        if (amount == 0) continue;
        breakdown.update(
          category.id,
          (current) => current + amount,
          ifAbsent: () => amount,
        );
      }
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
    final lines = <_CategoryLine>[];
    for (final expense in expenses) {
      for (final item in expense.items.where(
        (item) => item.category == category.id,
      )) {
        lines.add(
          _CategoryLine(expense: expense, name: item.name, amount: item.amount),
        );
      }
      final itemTotal = expense.items.fold<int>(
        0,
        (sum, item) => sum + item.amount,
      );
      final difference = expense.amount - itemTotal;
      if (expense.category == category.id && difference != 0) {
        lines.add(
          _CategoryLine(
            expense: expense,
            name: expense.items.isEmpty ? '支出合計' : '差額（税・値引き等）',
            amount: difference,
          ),
        );
      }
    }
    lines.sort((a, b) => b.expense.date.compareTo(a.expense.date));
    final total = lines.fold<int>(0, (sum, line) => sum + line.amount);
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
                  '${lines.length}件の明細 ・ ${_yen.format(total)}',
                  style: const TextStyle(color: Color(0xFF6D777B)),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: lines.isEmpty
                      ? const Center(child: Text('このカテゴリの記録はありません'))
                      : ListView(
                          children: lines
                              .map(
                                (line) => _CategoryLineTile(
                                  line: line,
                                  category: category,
                                  onTap: () => onExpense(line.expense),
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

class _CategoryLine {
  const _CategoryLine({
    required this.expense,
    required this.name,
    required this.amount,
  });

  final Expense expense;
  final String name;
  final int amount;
}

class _CategoryLineTile extends StatelessWidget {
  const _CategoryLineTile({
    required this.line,
    required this.category,
    required this.onTap,
  });

  final _CategoryLine line;
  final BudgetCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    color: const Color(0xFFFFFDF8),
    margin: const EdgeInsets.only(bottom: 9),
    child: ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: category.color.withValues(alpha: .13),
        foregroundColor: category.color,
        child: Icon(category.icon, size: 19),
      ),
      title: Text(
        line.name,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        '${_dateFormat.format(line.expense.date)} ・ '
        '${line.expense.merchant.isEmpty ? '名前のない記録' : line.expense.merchant}',
      ),
      trailing: Text(
        _yen.format(line.amount),
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
  );
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
  String _aiStatus = 'CHECKING';
  bool _checkingAi = false;

  @override
  void initState() {
    super.initState();
    _budget = TextEditingController(text: widget.budget.toString());
    _refreshAiStatus();
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

  Future<void> _refreshAiStatus() async {
    setState(() => _checkingAi = true);
    final status = await NanoGateway.checkStatus();
    if (!mounted) return;
    setState(() {
      _aiStatus = status;
      _checkingAi = false;
    });
  }

  Future<void> _downloadAi() async {
    setState(() {
      _aiStatus = 'DOWNLOADING';
      _checkingAi = true;
    });
    final status = await NanoGateway.downloadModel();
    if (!mounted) return;
    setState(() {
      _aiStatus = status;
      _checkingAi = false;
    });
  }

  String get _aiLabel => switch (_aiStatus) {
    'AVAILABLE' => 'Gemini Nano：利用できます',
    'DOWNLOADABLE' => 'Gemini Nano：ダウンロードできます',
    'DOWNLOADING' => 'Gemini Nano：準備中',
    'UNAVAILABLE' => 'Gemini Nano：この端末では非対応',
    'ERROR' => 'Gemini Nano：状態を確認できません',
    _ => 'Gemini Nano：確認中',
  };

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
                  _InfoLine(Icons.auto_awesome_outlined, 'レシート文字は端末内で読み取り'),
                ],
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              '端末内AI',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(17),
              decoration: _cardDecoration,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.memory_rounded, color: _sage),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _aiLabel,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (_checkingAi)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '対応端末では画像と文字を外部送信せずに解析します。非対応でもOCRと手入力は利用できます。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: Color(0xFF6D777B),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (_aiStatus == 'DOWNLOADABLE')
                        FilledButton.tonal(
                          onPressed: _checkingAi ? null : _downloadAi,
                          child: const Text('モデルを準備する'),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: _checkingAi ? null : _refreshAiStatus,
                        child: const Text('再確認'),
                      ),
                    ],
                  ),
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

class ReceiptPreviewPage extends StatefulWidget {
  const ReceiptPreviewPage({super.key, required this.imagePath});
  final String imagePath;

  @override
  State<ReceiptPreviewPage> createState() => _ReceiptPreviewPageState();
}

class _ReceiptPreviewPageState extends State<ReceiptPreviewPage> {
  var _isReading = false;
  ReceiptDraft? _draft;
  String? _error;
  String _nanoStatus = 'CHECKING';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readReceipt());
  }

  Future<void> _readReceipt() async {
    if (_isReading) return;
    setState(() {
      _isReading = true;
      _error = null;
    });
    TextRecognizer? recognizer;
    try {
      recognizer = TextRecognizer(script: TextRecognitionScript.japanese);
      final result = await recognizer
          .processImage(InputImage.fromFilePath(widget.imagePath))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final ocrDraft = ReceiptDraft.fromRecognizedText(
        widget.imagePath,
        result.text,
      );
      setState(() {
        _draft = ocrDraft;
        if (result.text.trim().isEmpty) {
          _error = '文字を検出できませんでした。明るい場所で、文字が正面に写るよう撮影してください。';
        }
      });
      final status = await NanoGateway.checkStatus();
      if (!mounted) return;
      setState(() => _nanoStatus = status);
      if (status == 'AVAILABLE' && result.text.trim().isNotEmpty) {
        setState(() => _nanoStatus = 'ANALYZING');
        try {
          final response = await NanoGateway.analyze(
            imagePath: widget.imagePath,
            ocrText: result.text,
          );
          if (!mounted) return;
          setState(() {
            _draft = ocrDraft.withNanoResponse(response);
            _nanoStatus = 'AVAILABLE';
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _nanoStatus = 'ERROR';
            _error = '端末内AIで内容を整理できませんでした。文字の読み取り候補を使って手入力できます。';
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '文字を読み取れませんでした。写真は添えたまま手入力で続けられます。');
      }
    } finally {
      await recognizer?.close();
      if (mounted) setState(() => _isReading = false);
    }
  }

  Future<void> _downloadNano() async {
    setState(() => _nanoStatus = 'DOWNLOADING');
    final result = await NanoGateway.downloadModel();
    if (!mounted) return;
    setState(() => _nanoStatus = result);
    if (result == 'AVAILABLE') {
      await _readReceipt();
    } else if (mounted) {
      setState(() => _error = '端末内AIを準備できませんでした。手入力はそのまま利用できます。');
    }
  }

  String get _nanoMessage => switch (_nanoStatus) {
    'AVAILABLE' =>
      _draft?.usedAi == true ? '端末内AIで内容を整理しました' : 'この端末ではGemini Nanoを利用できます',
    'ANALYZING' => '端末内AIで購入内容を整理しています…',
    'DOWNLOADABLE' => '端末内AIを追加で準備できます',
    'DOWNLOADING' => '端末内AIをダウンロードしています…',
    'UNAVAILABLE' => 'この端末ではOCR候補と手入力を利用します',
    'ERROR' => '端末内AIは利用できません。OCR候補は使用できます',
    _ => '端末内AIの状態を確認しています…',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _paper,
    appBar: AppBar(
      backgroundColor: _paper,
      title: const Text('写真を確認', style: TextStyle(fontWeight: FontWeight.w800)),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: ListView(
              children: [
                SizedBox(
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: ColoredBox(
                      color: const Color(0xFFF0EEE7),
                      child: Image.file(
                        File(widget.imagePath),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image_outlined,
                                size: 42,
                                color: _sage,
                              ),
                              SizedBox(height: 10),
                              Text('写真を表示できませんでした'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'この写真を添えて記録します',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                const Text(
                  '端末内で文字を読み取っています。内容は保存前に必ず確認・修正できます。',
                  style: TextStyle(color: Color(0xFF6D777B), height: 1.45),
                ),
                if (_isReading) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9EFE3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _sage,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text('レシートの文字を読み取っています…'),
                      ],
                    ),
                  ),
                ],
                if (_draft != null) ...[
                  const SizedBox(height: 14),
                  _OcrCandidateCard(draft: _draft!),
                ],
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F1E9),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _draft?.usedAi == true
                            ? Icons.auto_awesome_rounded
                            : Icons.memory_rounded,
                        size: 19,
                        color: _sage,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          _nanoMessage,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      if (_nanoStatus == 'DOWNLOADABLE')
                        TextButton(
                          onPressed: _downloadNano,
                          child: const Text('準備する'),
                        ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: _coral, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _isReading ? null : _readReceipt,
                  icon: _isReading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _paper,
                          ),
                        )
                      : const Icon(Icons.document_scanner_rounded),
                  label: Text(_isReading ? '端末内で読み取り中…' : 'もう一度読み取る'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _ink,
                    foregroundColor: _paper,
                    minimumSize: const Size.fromHeight(54),
                  ),
                ),
                const SizedBox(height: 9),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    _draft ?? ReceiptDraft(imagePath: widget.imagePath),
                  ),
                  icon: const Icon(Icons.edit_note_rounded),
                  label: Text(_draft == null ? '写真を添えて手入力へ' : '候補を確認・修正する'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _OcrCandidateCard extends StatelessWidget {
  const _OcrCandidateCard({required this.draft});
  final ReceiptDraft draft;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFE9EFE3),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 17, color: _sage),
            SizedBox(width: 7),
            Text('読み取り候補', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 8),
        Text('お店: ${draft.merchant ?? '未検出'}'),
        Text('金額: ${draft.amount == null ? '未検出' : _yen.format(draft.amount)}'),
        Text(
          '日付: ${draft.date == null ? '未検出' : _dateFormat.format(draft.date!)}',
        ),
        if (draft.payment?.isNotEmpty == true) Text('支払い: ${draft.payment}'),
        if (draft.items.isNotEmpty)
          Text(
            '明細: ${draft.items.length}件（${draft.items.map((item) => item.name).take(3).join('、')}）',
          ),
        if (draft.confidence != null)
          Text('読み取り信頼度: ${(draft.confidence! * 100).round()}%'),
        if (draft.warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              draft.warnings.join(' / '),
              style: const TextStyle(fontSize: 12, color: _coral),
            ),
          ),
        const SizedBox(height: 10),
        const Text(
          '読み取った文字',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: Color(0xFF5E6A61),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: const Color(0x88FFFFFF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            draft.rawText.trim().isEmpty
                ? '文字を検出できませんでした。写真を添えたまま手入力できます。'
                : draft.rawText.trim(),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 1.35),
          ),
        ),
      ],
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
              (_filter == 'all' || expense.amountForCategory(_filter) != 0) &&
              ('${expense.merchant} ${expense.note} ${expense.items.map((item) => item.name).join(' ')}'
                  .toLowerCase()
                  .contains(_query.toLowerCase())),
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
                  hintText: 'お店・商品・メモを検索',
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
    final purchaseRows = expenses
        .map(
          (expense) =>
              '| ${DateFormat('M/d').format(expense.date)} | ${_markdownCell(expense.merchant.isEmpty ? '—' : expense.merchant)} | ${categoryOf(expense.category).name} | ${_markdownCell(expense.payment)} | ${_markdownCell(expense.note.isEmpty ? '—' : expense.note)} | ${_yen.format(expense.amount)} |',
        )
        .join('\n');
    final categoryRows = categories
        .map(
          (category) => MapEntry(
            category,
            expenses.fold<int>(
              0,
              (sum, expense) => sum + expense.amountForCategory(category.id),
            ),
          ),
        )
        .where((entry) => entry.value != 0)
        .map(
          (entry) =>
              '| ${entry.key.name} | ${_yen.format(entry.value)} | ${(entry.value / max(total, 1) * 100).toStringAsFixed(1)}% |',
        )
        .join('\n');
    final itemRows = expenses
        .expand((expense) {
          return expense.items.map(
            (item) =>
                '| ${DateFormat('M/d').format(expense.date)} | ${_markdownCell(expense.merchant.isEmpty ? '—' : expense.merchant)} | ${_markdownCell(item.name)} | ${item.quantity} | ${categoryOf(item.category).name} | ${_yen.format(item.amount)} |',
          );
        })
        .join('\n');
    return '# ${DateFormat('yyyy年M月').format(month)} のくらし帳\n\n- 支出合計: ${_yen.format(total)}\n- 月の予算: ${_yen.format(budget)}\n- のこり: ${_yen.format(budget - total)}\n\n## カテゴリ別\n\n| カテゴリ | 金額 | 割合 |\n| --- | ---: | ---: |\n$categoryRows\n\n## 記録\n\n| 日付 | お店・内容 | 主カテゴリ | 支払方法 | メモ | 合計 |\n| --- | --- | --- | --- | --- | ---: |\n$purchaseRows\n\n## 商品・明細\n\n| 日付 | お店 | 商品・内容 | 数量 | カテゴリ | 金額 |\n| --- | --- | --- | ---: | --- | ---: |\n$itemRows\n';
  }

  String _markdownCell(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', ' ');

  Future<void> _shareMarkdown(BuildContext context) async {
    final directory = await getApplicationDocumentsDirectory();
    final filename = 'household_${DateFormat('yyyy-MM').format(month)}.md';
    final file = File('${directory.path}${Platform.pathSeparator}$filename');
    await file.writeAsString(_markdown, encoding: utf8);
    await SharePlus.instance.share(
      ShareParams(
        text: '${_monthFormat.format(month)}のくらし帳',
        files: [XFile(file.path)],
      ),
    );
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
                    const SizedBox(height: 9),
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await _shareMarkdown(context);
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('ファイルを書き出せませんでした')),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('ファイルとして共有・保存'),
                      style: OutlinedButton.styleFrom(
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
    this.draft,
  });
  final Expense? initial;
  final String? imagePath;
  final bool fromScan;
  final ReceiptDraft? draft;
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
  late List<ExpenseItem> _items;

  int get _itemTotal => _items.fold<int>(0, (sum, item) => sum + item.amount);

  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    final draft = widget.draft;
    _merchant = TextEditingController(
      text: value?.merchant ?? draft?.merchant ?? '',
    );
    _amount = TextEditingController(
      text: value?.amount.toString() ?? draft?.amount?.toString() ?? '',
    );
    _note = TextEditingController(text: value?.note ?? '');
    _date = value?.date ?? draft?.date ?? DateTime.now();
    _category = value?.category ?? draft?.category ?? 'other';
    _payment = value?.payment ?? draft?.payment ?? '現金';
    _items = [...?value?.items, ...?draft?.items];
    if (_items.isEmpty && draft?.amount != null) {
      _items.add(
        ExpenseItem(
          id: '${DateTime.now().microsecondsSinceEpoch}-item',
          name: draft?.merchant?.isNotEmpty == true ? draft!.merchant! : '購入品',
          quantity: 1,
          amount: draft!.amount!,
          category: _category,
        ),
      );
    }
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
    final expenseId =
        widget.initial?.id ?? '${DateTime.now().microsecondsSinceEpoch}';
    final items = _items.isEmpty
        ? [
            ExpenseItem(
              id: '$expenseId-item-0',
              name: _merchant.text.trim().isEmpty
                  ? '支出'
                  : _merchant.text.trim(),
              quantity: 1,
              amount: amount,
              category: _category,
            ),
          ]
        : List<ExpenseItem>.unmodifiable(_items);
    Navigator.pop(
      context,
      Expense(
        id: expenseId,
        merchant: _merchant.text.trim(),
        amount: amount,
        date: _date,
        category: _category,
        note: _note.text.trim(),
        payment: _payment,
        source: widget.fromScan ? 'image' : 'manual',
        imagePath: widget.imagePath ?? widget.initial?.imagePath,
        items: items,
      ),
    );
  }

  Future<void> _editItem([ExpenseItem? item]) async {
    final edited = await showDialog<ExpenseItem>(
      context: context,
      builder: (_) => ExpenseItemDialog(
        initial: item,
        defaultCategory: item?.category ?? _category,
      ),
    );
    if (edited == null) return;
    setState(() {
      final index = _items.indexWhere((value) => value.id == edited.id);
      if (index < 0) {
        _items.add(edited);
      } else {
        _items[index] = edited;
      }
      if (_items.length == 1) _category = edited.category;
      _amount.text = _itemTotal.toString();
    });
  }

  void _removeItem(ExpenseItem item) {
    setState(() {
      _items.removeWhere((value) => value.id == item.id);
      if (_items.isNotEmpty) _amount.text = _itemTotal.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    final imagePath = widget.imagePath ?? widget.initial?.imagePath;
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
                if (imagePath != null) ...[
                  const Text(
                    '添付した写真',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  ReceiptImageCard(imagePath: imagePath),
                  const SizedBox(height: 18),
                ],
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
                  onChanged: (_) => setState(() {}),
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
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: _cardDecoration,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '商品・明細',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '品目ごとにカテゴリを分けられます',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF6D777B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _editItem,
                            icon: const Icon(Icons.add_rounded, size: 19),
                            label: const Text('追加'),
                          ),
                        ],
                      ),
                      if (_items.isEmpty)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(top: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F1E9),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: const Text(
                            '明細はまだありません。追加しなくても合計金額で記録できます。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF687174),
                            ),
                          ),
                        )
                      else ...[
                        const SizedBox(height: 8),
                        ..._items.map(
                          (item) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                backgroundColor: categoryOf(
                                  item.category,
                                ).color.withValues(alpha: .13),
                                foregroundColor: categoryOf(
                                  item.category,
                                ).color,
                                child: Icon(
                                  categoryOf(item.category).icon,
                                  size: 19,
                                ),
                              ),
                              title: Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                '${categoryOf(item.category).name} ・ ${item.quantity}点',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _yen.format(item.amount),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    onSelected: (action) {
                                      if (action == 'edit') {
                                        _editItem(item);
                                      } else {
                                        _removeItem(item);
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text('編集'),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('削除'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () => _editItem(item),
                            ),
                          ),
                        ),
                        const Divider(height: 18),
                        Row(
                          children: [
                            const Text(
                              '明細の合計',
                              style: TextStyle(color: Color(0xFF6D777B)),
                            ),
                            const Spacer(),
                            Text(
                              _yen.format(_itemTotal),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        if (int.tryParse(_amount.text.replaceAll(',', '')) !=
                            _itemTotal)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              '合計金額との差額は、上で選んだ主カテゴリに集計されます。',
                              style: TextStyle(fontSize: 11, color: _coral),
                            ),
                          ),
                      ],
                    ],
                  ),
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
    ValueChanged<String>? onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: keyboard,
        onChanged: onChanged,
        decoration: _inputDecoration(hint: hint, prefix: prefix),
      ),
    ],
  );
}

class ExpenseItemDialog extends StatefulWidget {
  const ExpenseItemDialog({
    super.key,
    this.initial,
    required this.defaultCategory,
  });

  final ExpenseItem? initial;
  final String defaultCategory;

  @override
  State<ExpenseItemDialog> createState() => _ExpenseItemDialogState();
}

class _ExpenseItemDialogState extends State<ExpenseItemDialog> {
  late final TextEditingController _name;
  late final TextEditingController _quantity;
  late final TextEditingController _amount;
  late String _category;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _quantity = TextEditingController(
      text: (widget.initial?.quantity ?? 1).toString(),
    );
    _amount = TextEditingController(
      text: widget.initial?.amount.toString() ?? '',
    );
    _category = widget.initial?.category ?? widget.defaultCategory;
  }

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final quantity = int.tryParse(_quantity.text);
    final amount = int.tryParse(_amount.text.replaceAll(',', ''));
    if (_name.text.trim().isEmpty ||
        quantity == null ||
        quantity <= 0 ||
        amount == null ||
        amount <= 0) {
      setState(() => _error = '商品名・数量・金額を正しく入力してください。');
      return;
    }
    Navigator.pop(
      context,
      ExpenseItem(
        id:
            widget.initial?.id ??
            '${DateTime.now().microsecondsSinceEpoch}-item',
        name: _name.text.trim(),
        quantity: quantity,
        amount: amount,
        category: _category,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '明細を追加' : '明細を編集'),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(hint: '商品・サービス名'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quantity,
                    keyboardType: TextInputType.number,
                    decoration: _inputDecoration(hint: '数量'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _amount,
                    keyboardType: TextInputType.number,
                    decoration: _inputDecoration(hint: '明細の合計', prefix: '¥'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: _inputDecoration(),
              items: categories
                  .map(
                    (category) => DropdownMenuItem(
                      value: category.id,
                      child: Row(
                        children: [
                          Icon(category.icon, size: 18, color: category.color),
                          const SizedBox(width: 8),
                          Text(category.name),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _category = value!),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: _coral),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(onPressed: _submit, child: const Text('反映する')),
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

class ReceiptImageCard extends StatelessWidget {
  const ReceiptImageCard({
    super.key,
    required this.imagePath,
    this.height = 190,
  });
  final String imagePath;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: ColoredBox(
        color: const Color(0xFFF0EEE7),
        child: Image.file(
          File(imagePath),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, color: _sage),
                SizedBox(height: 6),
                Text('写真を表示できませんでした'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

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
          child: ListView(
            padding: const EdgeInsets.all(20),
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
              if (expense.imagePath != null) ...[
                const SizedBox(height: 18),
                const Text(
                  '添付写真',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                ReceiptImageCard(imagePath: expense.imagePath!, height: 118),
              ],
              if (expense.items.isNotEmpty) ...[
                const SizedBox(height: 22),
                const Text(
                  '商品・明細',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: _cardDecoration,
                  child: Column(
                    children: expense.items
                        .map(
                          (item) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: Icon(
                              categoryOf(item.category).icon,
                              size: 20,
                              color: categoryOf(item.category).color,
                            ),
                            title: Text(
                              item.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${categoryOf(item.category).name} ・ ${item.quantity}点',
                            ),
                            trailing: Text(
                              _yen.format(item.amount),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: _cardDecoration,
                child: Column(
                  children: [
                    _detailRow('カテゴリ', category.name),
                    _detailRow('支払い方法', expense.payment),
                    if (expense.note.isNotEmpty) _detailRow('メモ', expense.note),
                    _detailRow(
                      '記録方法',
                      expense.source == 'image' ? '画像を添えて記録' : '手動入力',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
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
                          style: TextButton.styleFrom(foregroundColor: _coral),
                          child: const Text('削除する'),
                        ),
                      ],
                    ),
                  );
                  if (context.mounted && confirm == true) {
                    Navigator.pop(context, const _ExpenseAction(delete: true));
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
