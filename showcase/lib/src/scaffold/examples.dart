import 'package:zap/zap.dart';

import '../examples/introduction/hello_world.zap.dart' as i1;
import '../examples/introduction/styling.zap.dart' as i2;
import '../examples/introduction/nested/index.zap.dart' as i3;
import '../examples/introduction/raw_html.zap.dart' as i4;
import '../examples/reactivity/assignments.zap.dart' as rx;
import '../examples/reactivity/declarations.zap.dart' as rx;
import '../examples/reactivity/statements.zap.dart' as rx;
import '../examples/watchable/writable/counter.zap.dart' as watch;
import '../examples/watchable/time.zap.dart' as watch;

final selectedComponent = WritableWatchable(groups.first.children.first);

class ExampleGroup {
  final String title;
  final List<ExampleComponent> children;

  const ExampleGroup({required this.title, required this.children});
}

class ExampleComponent {
  final String title;
  final String id;
  final ZapComponent Function() create;

  const ExampleComponent(this.title, this.id, this.create);
}

const groups = <ExampleGroup>[
  ExampleGroup(
    title: 'Introduction',
    children: [
      ExampleComponent('Hello world', 'hello-world', i1.hello_world.new),
      ExampleComponent('Styling', 'simple-styling', i2.styling.new),
      ExampleComponent('Nested components', 'simple-nested', i3.index.new),
      ExampleComponent('HTML tags', 'raw-html', i4.raw_html.new),
    ],
  ),
  ExampleGroup(
    title: 'Reactivity',
    children: [
      ExampleComponent('Reactive assignments', 'rx-assign', rx.assignments.new),
      ExampleComponent('Reactive declarations', 'rx-decl', rx.declarations.new),
      ExampleComponent('Reactive statements', 'rx-stmts', rx.statements.new),
    ],
  ),
  ExampleGroup(
    title: 'Watchables',
    children: [
      ExampleComponent('Readable', 'watch-read', watch.time.new),
      ExampleComponent('Writable', 'watch-write', watch.counter.new),
    ],
  ),
];