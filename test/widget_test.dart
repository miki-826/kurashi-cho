import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_ai/database.dart';
import 'package:household_ai/main.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ja_JP'));

  test('unknown category resolves to other', () {
    expect(categoryOf('missing').id, 'other');
  });

  test('receipt OCR candidate extracts total and date', () {
    final draft = ReceiptDraft.fromRecognizedText(
      '/tmp/receipt.jpg',
      '八百屋みどり\n2026/07/30\n合計 ¥1,280',
    );
    expect(draft.merchant, '八百屋みどり');
    expect(draft.amount, 1280);
    expect(draft.date, DateTime(2026, 7, 30));
  });

  test('legacy expense receives a fallback item during migration', () {
    final expense = Expense.fromJson({
      'id': 'legacy-1',
      'merchant': '八百屋みどり',
      'amount': 1280,
      'date': '2026-07-30T00:00:00.000',
      'category': 'food',
      'note': '',
      'payment': '現金',
      'source': 'manual',
    });

    expect(expense.items, hasLength(1));
    expect(expense.items.single.amount, 1280);
    expect(expense.amountForCategory('food'), 1280);
  });

  test('uncategorized difference is allocated to the primary category', () {
    final expense = Expense(
      id: 'mixed-1',
      merchant: 'スーパー',
      amount: 1500,
      date: DateTime(2026, 7, 30),
      category: 'food',
      note: '',
      payment: '現金',
      source: 'manual',
      items: const [
        ExpenseItem(
          id: 'food-1',
          name: '野菜',
          quantity: 1,
          amount: 900,
          category: 'food',
        ),
        ExpenseItem(
          id: 'daily-1',
          name: '洗剤',
          quantity: 1,
          amount: 500,
          category: 'daily',
        ),
      ],
    );

    expect(expense.amountForCategory('food'), 1000);
    expect(expense.amountForCategory('daily'), 500);
  });

  test('purchase and items are saved and deleted in one database', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final expense = Expense(
      id: 'db-1',
      merchant: '商店',
      amount: 500,
      date: DateTime(2026, 7, 30),
      category: 'food',
      note: '',
      payment: '現金',
      source: 'manual',
      items: const [
        ExpenseItem(
          id: 'db-item-1',
          name: 'パン',
          quantity: 2,
          amount: 500,
          category: 'food',
        ),
      ],
    );

    await database.replaceExpense(expense.toJson());
    final stored = await database.loadExpenses();
    expect(stored, hasLength(1));
    expect(stored.single['items'], hasLength(1));

    await database.removeExpense(expense.id);
    expect(await database.loadExpenses(), isEmpty);
  });

  testWidgets('manual editor accepts merchant and amount input', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ExpenseEditor()));

    final fields = find.byType(TextField);
    expect(fields, findsAtLeastNWidgets(2));
    await tester.enterText(fields.at(0), '入力できる店');
    await tester.enterText(fields.at(1), '1234');

    expect(find.text('入力できる店'), findsOneWidget);
    expect(find.text('1234'), findsOneWidget);
  });
}
