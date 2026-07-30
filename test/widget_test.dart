import 'package:flutter_test/flutter_test.dart';
import 'package:household_ai/main.dart';

void main() {
  test('unknown category resolves to other', () {
    expect(categoryOf('missing').id, 'other');
  });
}
