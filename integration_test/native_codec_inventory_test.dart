import 'package:integration_test/integration_test.dart';
import '../test/native_codec_inventory_test.dart' as inventory;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  inventory.main();
}
