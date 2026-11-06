import 'package:integration_test/integration_test.dart';
import '../test/native_codec_inventory_test.dart' as inventory;
import 'playback_compatibility_test.dart' as playback;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  inventory.main();
  playback.main();
}
