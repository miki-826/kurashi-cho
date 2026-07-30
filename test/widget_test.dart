import 'package:flutter_test/flutter_test.dart';
import 'package:household_ai/main.dart';

void main() {
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
}
