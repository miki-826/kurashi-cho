import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class Purchases extends Table {
  TextColumn get id => text()();
  TextColumn get merchant => text().withDefault(const Constant(''))();
  IntColumn get amount => integer()();
  DateTimeColumn get purchasedAt => dateTime()();
  TextColumn get category => text().withDefault(const Constant('other'))();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get payment => text().withDefault(const Constant('現金'))();
  TextColumn get source => text().withDefault(const Constant('manual'))();
  TextColumn get imagePath => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PurchaseItems extends Table {
  TextColumn get id => text()();
  TextColumn get purchaseId =>
      text().references(Purchases, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  IntColumn get quantity => integer().withDefault(const Constant(1))();
  IntColumn get amount => integer()();
  TextColumn get category => text().withDefault(const Constant('other'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class MonthlyBudgets extends Table {
  TextColumn get monthKey => text()();
  IntColumn get amount => integer()();

  @override
  Set<Column<Object>> get primaryKey => {monthKey};
}

@DriftDatabase(tables: [Purchases, PurchaseItems, MonthlyBudgets])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openDatabase());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  Future<List<Map<String, dynamic>>> loadExpenses() async {
    final purchaseRows = await select(purchases).get();
    final result = <Map<String, dynamic>>[];
    for (final purchase in purchaseRows) {
      final itemRows =
          await (select(purchaseItems)
                ..where((item) => item.purchaseId.equals(purchase.id))
                ..orderBy([(item) => OrderingTerm.asc(item.sortOrder)]))
              .get();
      result.add({
        'id': purchase.id,
        'merchant': purchase.merchant,
        'amount': purchase.amount,
        'date': purchase.purchasedAt.toIso8601String(),
        'category': purchase.category,
        'note': purchase.note,
        'payment': purchase.payment,
        'source': purchase.source,
        'imagePath': purchase.imagePath,
        'items': itemRows
            .map(
              (item) => {
                'id': item.id,
                'name': item.name,
                'quantity': item.quantity,
                'amount': item.amount,
                'category': item.category,
              },
            )
            .toList(),
      });
    }
    return result;
  }

  Future<void> replaceExpense(Map<String, dynamic> json) async {
    await transaction(() async {
      await into(purchases).insertOnConflictUpdate(
        PurchasesCompanion.insert(
          id: json['id'] as String,
          merchant: Value(json['merchant'] as String? ?? ''),
          amount: json['amount'] as int,
          purchasedAt: DateTime.parse(json['date'] as String),
          category: Value(json['category'] as String? ?? 'other'),
          note: Value(json['note'] as String? ?? ''),
          payment: Value(json['payment'] as String? ?? '現金'),
          source: Value(json['source'] as String? ?? 'manual'),
          imagePath: Value(json['imagePath'] as String?),
        ),
      );
      await (delete(
        purchaseItems,
      )..where((item) => item.purchaseId.equals(json['id'] as String))).go();
      final rawItems = json['items'] as List<dynamic>? ?? const [];
      for (var index = 0; index < rawItems.length; index++) {
        final item = rawItems[index] as Map<String, dynamic>;
        await into(purchaseItems).insert(
          PurchaseItemsCompanion.insert(
            id: item['id'] as String,
            purchaseId: json['id'] as String,
            name: item['name'] as String,
            quantity: Value(item['quantity'] as int? ?? 1),
            amount: item['amount'] as int,
            category: Value(item['category'] as String? ?? 'other'),
            sortOrder: Value(index),
          ),
        );
      }
    });
  }

  Future<void> removeExpense(String id) async {
    await (delete(purchases)..where((purchase) => purchase.id.equals(id))).go();
  }

  Future<Map<String, int>> loadBudgets() async {
    final rows = await select(monthlyBudgets).get();
    return {for (final row in rows) row.monthKey: row.amount};
  }

  Future<void> saveBudget(String monthKey, int value) async {
    await into(monthlyBudgets).insertOnConflictUpdate(
      MonthlyBudgetsCompanion.insert(monthKey: monthKey, amount: value),
    );
  }
}

LazyDatabase _openDatabase() => LazyDatabase(() async {
  final directory = await getApplicationDocumentsDirectory();
  final file = File(
    '${directory.path}${Platform.pathSeparator}household_ai.sqlite',
  );
  return NativeDatabase.createInBackground(file);
});
