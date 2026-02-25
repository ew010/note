import 'package:flutter_test/flutter_test.dart';
import 'package:note/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders Notion Lite shell', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const NotesApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Pages'), findsOneWidget);
  });
}
