import 'package:flutter_test/flutter_test.dart';

import '../tool/check_whole_book_preflight.dart' as checks;

void main() {
  test('whole-book preflight preserves identity, limits, order and cost', checks.main);
}
