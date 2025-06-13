import 'package:zap_dev/src/errors.dart';
import 'package:zap_dev/src/resolver/extract_api.dart';
import 'package:zap_dev/src/resolver/preparation.dart';

const String code = '''
<script>
  import 'dart:html';

  import 'package:zap/zap.dart';

  @prop
  Watchable<int> watchable;
</script>

Current value is {watch(watchable)}.
''';

Future<void> main() async {
  PrepareResult result = await prepare(
    code,
    Uri.parse('package:foo/bar.zap'),
    ErrorReporter(print),
  );

  TemporaryDartFile temporaryDartFile = result.temporaryDartFile;
  print(temporaryDartFile.contents);

  String api = writeApiForComponent(
    null,
    temporaryDartFile.contents,
    'package:foo/bar.tmp.zap.api.dart',
  );

  print(api);
}
