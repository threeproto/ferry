import 'package:flutter_test/flutter_test.dart';
import 'package:ferry/main.dart';
import 'package:ferry/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('App launches to setup screen', (WidgetTester tester) async {
    await tester.pumpWidget(const FerryApp(home: SetupScreen()));
    expect(find.text('Ferry'), findsOneWidget);
  });
}
