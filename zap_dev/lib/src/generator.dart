import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import 'resolver/flow.dart';
import 'resolver/model.dart';
import 'resolver/preparation.dart';
import 'resolver/reactive_dom.dart';
import 'resolver/variable.dart';
import 'utils/dart.dart';

const _prefix = r'_$';
const _parentField = '${_prefix}parent';

class Generator {
  final String name;
  final PrepareResult prepareResult;
  final ResolvedComponent component;
  final StringBuffer buffer = StringBuffer();

  final Map<Variable, String> _varNames = {};
  final Map<ReactiveNode, String> _nodeNames = {};
  final Map<FunctionElement, String> _functionNames = {};
  final Map<Object, String> _miscNames = {};

  Generator(this.name, this.prepareResult, this.component);

  String _nameForVar(Variable variable) {
    return _varNames.putIfAbsent(variable, () {
      return '${_prefix}v${_varNames.length}';
    });
  }

  String _nameForNode(ReactiveNode node) {
    return _nodeNames.putIfAbsent(node, () {
      return '${_prefix}n${_nodeNames.length}';
    });
  }

  String _nameForFunction(FunctionElement fun) {
    return _functionNames.putIfAbsent(fun, () => '${_prefix}fun_${fun.name}');
  }

  String _nameForMisc(Object key) {
    return _miscNames.putIfAbsent(
        key, () => '_${_prefix}t${_miscNames.length}');
  }

  bool _isZapFragment(ReactiveNode node) =>
      node is SubComponent || node is ReactiveIf;

  bool _passesDownUpdates(ReactiveNode node) => node is ReactiveIf;

  bool _isInitializedLater(ReactiveNode node) => _isZapFragment(node);

  void write() {
    final imports = ScriptComponents.of(prepareResult.temporaryDartFile,
            rewriteImports: ImportRewriteMode.apiToGenerated)
        .directives;

    buffer
      ..writeln('// Generated by zap_dev, do not edit!')
      ..writeln("import 'dart:html' as $_prefix;")
      // We're importing zap with and without a name to use extensions while
      // also avoiding naming conflicts otherwise.
      ..writeln("import 'package:zap/zap.dart';")
      ..writeln("import 'package:zap/zap.dart' as $_prefix;")
      ..writeln(imports);
    writeFragments();
    writeMainComponent();
  }

  void writeFragments() {
    for (final node in component.allNodes) {
      if (node is ReactiveIf) {
        node.fragmentsForWhen?.forEach(writeFragment);
        final otherwise = node.fragmentForOtherwise;
        if (otherwise != null) {
          writeFragment(otherwise);
        }
      }
    }
  }

  void writeFragment(SubFragment fragment) {
    final name = _nameForMisc(fragment);
    buffer.writeln('class $name extends $_prefix.Fragment {');

    buffer
      ..writeln('final ${this.name} $_parentField;')
      ..writeln('$name(this.$_parentField);');

    writeNodesAndBlockHelpers(fragment);
    writeCreateMethod(fragment);
    writeMountMethod(fragment);
    writeUpdateMethod(fragment);
    writeRemoveMethod(fragment);

    buffer.writeln('}');
  }

  void writeMainComponent() {
    buffer.writeln('class $name extends $_prefix.ZapComponent {');

    final variablesToInitialize = [];

    // Write variables:
    for (final variable in component.dartDeclarations.values) {
      if (!variable.isMutable) buffer.write('final ');

      final name = _nameForVar(variable);
      buffer
        ..write(variable.declaredElement.type
            .getDisplayString(withNullability: true))
        ..write(' ')
        ..write(name)
        ..write(';')
        ..writeln(' // ${variable.declaredElement.name}');

      variablesToInitialize.add(name);
    }

    // And DOM nodes
    writeNodesAndBlockHelpers(component);

    // Mutable stream subscriptions are stored as instance variables too
    for (final flow in component.updateEvents) {
      final action = flow.action;
      if (!flow.isOneOffAction && action is RegisterEventHandler) {
        buffer
          ..write('late ')
          ..write('StreamSubscription<$_prefix')
          ..write(action.handler.effectiveEventType)
          ..write('> ')
          ..write(_nameForMisc(action.handler))
          ..writeln(';');
      }
    }

    // Write a private constructor taking all variables and elements
    buffer
      ..write(name)
      ..write('._(')
      ..write(variablesToInitialize.map((e) => 'this.$e').join(', '))
      ..writeln(');');

    writeFactory();

    writeCreateMethod(component);
    writeMountMethod(component);
    writeRemoveMethod(component);
    writeUpdateMethod(component);
    writePropertyAccessors();

    // Write functions that were declared in the component
    for (final statement in component.instanceFunctions) {
      writeDartWithPatchedReferences(statement.functionDeclaration, component);
    }

    buffer.writeln('}');
  }

  void writeNodesAndBlockHelpers(ComponentOrFragment component) {
    // Write instance fields storing nodes
    for (final node in component.allNodes) {
      final name = _nameForNode(node);
      final isInitializedLater = _isInitializedLater(node);

      if (isInitializedLater) {
        buffer.write('late ');
      }

      buffer
        ..write('final ')
        ..write(node.dartTypeName!)
        ..write(' ')
        ..write(name);

      if (!isInitializedLater) {
        buffer.write(' = ');
        createNode(node, component);
      }

      buffer.writeln(';');

      if (node is ReactiveIf) {
        // Write a function used to evaluate the condition for an if block
        final name = _nameForMisc(node);
        buffer.writeln('int $name() {');
        for (var i = 0; i < node.conditions.length; i++) {
          if (i != 0) {
            buffer.write('else ');
          }
          buffer.write('if(');
          writeDartWithPatchedReferences(node.conditions[i], component);
          buffer
            ..writeln(') {')
            ..writeln('  return $i;')
            ..writeln('}');
        }
        buffer.writeln('else { return ${node.conditions.length}; }}');
      }
    }
  }

  void writeFactory() {
    // Properties can be used in the initialization code, so we create
    // constructor properties for them.
    buffer
      ..write('factory ')
      ..write(name)
      ..write('(');

    final properties = component.dartDeclarations.values.where((v) => v.isProp);

    for (final variable in properties) {
      // Wrap properties in a ZapValue so that we can fallback to the default
      // value otherwise. We can't use optional parameters as the default
      // doesn't have to be a constant.
      // todo: Don't do that if the parameter is non-nulallable
      final element = variable.declaredElement;
      final innerType = element.type.getDisplayString(withNullability: true);
      final type = '$_prefix.ZapValue<$innerType>?';
      buffer
        ..write(type)
        ..write(r' $')
        ..write(element.name)
        ..write(',');
    }

    buffer.writeln(') {');

    // Write all statements for the initializer
    for (final initializer in component.componentInitializers) {
      if (initializer is InitializeStatement) {
        writeUnchangedDartCode(initializer.dartStatement);
      } else if (initializer is InitializeProperty) {
        // We have the property as $property, wrapped in a nullable
        // ZapValue.
        // So write `<type> variable = $variable != null ? $variable.value : <d>`
        final variable = initializer.variable;
        final element = variable.declaredElement;

        buffer
          ..write(element.type.getDisplayString(withNullability: true))
          ..write(' ')
          ..write(element.name)
          ..write(r' = $')
          ..write(element.name)
          ..write(' != null ? ')
          ..write(r'$')
          ..write(element.name)
          ..write('.value : (');

        final defaultExpr = variable.declaration.initializer;
        if (defaultExpr != null) {
          writeUnchangedDartCode(defaultExpr);
        } else {
          // No initializer and no value set -> error
          buffer.write(
              'throw ArgumentError(${dartStringLiteral('Parameter ${element.name} is required!')})');
        }

        buffer.write(');');
      }
    }

    // Write call to constructor.
    buffer.write('return $name._(');

    // Write instantiated variables first
    for (final variable in component.dartDeclarations.values) {
      // Variables are created for initializer statements that appear in the
      // code we've just written.
      buffer
        ..write(variable.declaredElement.name)
        ..write(',');
    }

    buffer.writeln(');}');
  }

  void createNode(ReactiveNode node, ComponentOrFragment component) {
    if (node is ReactiveElement) {
      final known = node.knownElement;

      if (known != null) {
        final type = '$_prefix.${known.className}';

        if (known.instantiable) {
          // Use a direct constructor provided by the Dart SDK
          buffer.write(type);
          if (known.constructorName.isNotEmpty) {
            buffer.write('.${known.constructorName}');
          }

          buffer.write('()');
        } else {
          // Use the newElement helper method from zap
          buffer.write(
              '$_prefix.newElement<$type>(${dartStringLiteral(node.tagName)})');
        }
      } else {
        buffer.write("$_prefix.Element.tag('${node.tagName}')");
      }
    } else if (node is ReactiveText) {
      buffer.write("$_prefix.Text('')");
    } else if (node is ConstantText) {
      buffer.write("$_prefix.Text(${dartStringLiteral(node.text)})");
    } else if (node is SubComponent) {
      buffer
        ..write(node.component.className)
        ..write('(');

      for (final property in node.component.parameters) {
        final name = property.key;
        final actualValue = node.expressions[name];

        if (actualValue == null) {
          buffer.write('null');
        } else {
          // Wrap values in a ZapBox to distinguish between set and absent
          // parameters.
          buffer.write('$_prefix.ZapValue(');
          writeDartWithPatchedReferences(actualValue, component);
          buffer.write(')');
        }

        buffer.write(',');
      }
      buffer.writeln(')..create()');
    } else if (node is ReactiveIf) {
      buffer
        ..writeln('$_prefix.IfBlock((caseNum) {')
        ..writeln('switch (caseNum) {');

      for (var i = 0; i < node.whens.length; i++) {
        final fragment = node.fragmentsForWhen![i];
        final name = _nameForMisc(fragment);

        buffer.writeln('case $i: return $name(this);');
      }

      final defaultCase = node.fragmentForOtherwise;
      if (defaultCase != null) {
        final name = _nameForMisc(defaultCase);
        buffer.writeln('default: return $name(this);');
      } else {
        buffer.writeln('default: return null;');
      }

      buffer.writeln('}})..create()');
    } else {
      throw ArgumentError('Unknown node type: $node');
    }
  }

  void writeCreateMethod(ComponentOrFragment component) {
    final name = component is SubFragment ? 'create' : 'createInternal';

    buffer
      ..writeln('@override')
      ..writeln('void $name() {');

    // Create subcomponents. They require evaluating Dart expressions, so we
    // can't do this earlier.
    for (final node in component.allNodes) {
      if (_isInitializedLater(node)) {
        buffer
          ..write(_nameForNode(node))
          ..write(' = ');
        createNode(node, component);
        buffer.writeln(';');
      }
    }

    // In the create method, we set the initial value of Dart expressions and
    // register event handlers.
    for (final flow in component.updateEvents) {
      writeFlowAction(flow, component, isInCreate: true);
    }

    buffer.writeln('}');
  }

  void writeMountMethod(ComponentOrFragment component) {
    final name = component is SubFragment ? 'mount' : 'mountInternal';

    buffer
      ..writeln('@override')
      ..writeln(
          'void $name($_prefix.Element target, [$_prefix.Node? anchor]) {');

    void writeAdd(Iterable<ReactiveNode> nodes, String target, String? anchor) {
      for (final node in nodes) {
        final name = _nameForNode(node);

        if (_isZapFragment(node)) {
          buffer
            ..write(name)
            ..writeln('.mount($target, $anchor);');
          continue;
        } else if (anchor == null) {
          // Write an append call
          buffer.writeln('$target.append($name);');
        } else {
          // Use insertBefore then
          buffer.writeln('$target.insertBefore($name, $anchor);');
        }

        // Mount child nodes as well
        writeAdd(node.children, name, null);
      }
    }

    writeAdd(component.root, 'target', 'anchor');
    buffer.writeln('}');
  }

  void writeRemoveMethod(ComponentOrFragment component) {
    final name = component is SubFragment ? 'destroy' : 'remove';

    buffer
      ..writeln('@override')
      ..writeln('void $name() {');

    for (final rootNode in component.root) {
      buffer.write(_nameForNode(rootNode));

      if (_isZapFragment(rootNode)) {
        buffer.write('.destroy();');
      } else {
        buffer.write('.remove();');
      }
    }

    buffer.writeln('}');
  }

  void writeUpdateMethod(ComponentOrFragment component) {
    buffer
      ..writeln('@override')
      ..writeln('void update(int delta) {');

    for (final flow in component.updateEvents) {
      if (!flow.isOneOffAction) {
        buffer
          ..write('if (delta & ')
          ..write(flow.bitmask)
          ..writeln(' != 0) {');
        writeFlowAction(flow, component);
        buffer.writeln('}');
      }
    }

    // Some nodes manage subcomponents and need to be updated as well
    for (final node in component.allNodes.where(_passesDownUpdates)) {
      final name = _nameForNode(node);
      buffer.writeln('$name.update(delta);');
    }

    buffer.writeln('}');
  }

  void writeFlowAction(Flow flow, ComponentOrFragment component,
      {bool isInCreate = false}) {
    final action = flow.action;

    if (action is SideEffect) {
      writeDartWithPatchedReferences(action.statement, component);
    } else if (action is ChangeText) {
      writeSetText(action.text, component);
    } else if (action is RegisterEventHandler) {
      final handler = action.handler;
      if (flow.isOneOffAction) {
        // Just register the event handler, it won't be changed later!
        registerEventHandler(handler, component);
      } else {
        if (isInCreate) {
          // We need to store the result of listening in a stream subscription
          // so that the event handler can be changed later.
          buffer
            ..write(_nameForMisc(handler))
            ..write(' = ');
          registerEventHandler(handler, component);
        } else {
          // Just change the onData callback of the stream subscription now
          buffer
            ..write(_nameForMisc(handler))
            ..write('onData(');
          callbackForEventHandler(handler, component);
          buffer.writeln(');');
        }
      }
    } else if (action is ApplyAttribute) {
      final attribute = action.element.attributes[action.name]!;
      final nodeName = _nameForNode(action.element);

      switch (attribute.mode) {
        case AttributeMode.setValue:
          // Just emit node.attributes[key] = value.toString()
          buffer
            ..write(nodeName)
            ..write("attributes['")
            ..write(action.name)
            ..write("'] = ");
          writeDartWithPatchedReferences(
              attribute.backingExpression, component);
          buffer.writeln('.toString();');
          break;
        case AttributeMode.addIfTrue:
          // Emit node.applyBooleanAttribute(key, value)
          buffer
            ..write(nodeName)
            ..write(".applyBooleanAttribute('")
            ..write(action.name)
            ..write("', ");
          writeDartWithPatchedReferences(
              attribute.backingExpression, component);
          buffer.writeln(');');
          break;
        case AttributeMode.setIfNotNullClearOtherwise:
          buffer
            ..write(nodeName)
            ..write(".applyAttributeIfNotNull('")
            ..write(action.name)
            ..write("', ");
          writeDartWithPatchedReferences(
              attribute.backingExpression, component);
          buffer.writeln(');');
          break;
      }
    } else if (action is UpdateIf) {
      final nodeName = _nameForNode(action.node);
      final nameOfBranchFunction = _nameForMisc(action.node);

      buffer
        ..write(nodeName)
        ..write('.reEvaluate($nameOfBranchFunction());');
    }
  }

  void registerEventHandler(
      EventHandler handler, ComponentOrFragment component) {
    final knownEvent = handler.knownType;
    final node = _nameForNode(handler.parent);

    buffer
      ..write(node)
      ..write('.');

    if (knownEvent != null) {
      // Use the known Dart getter for the event stream
      buffer.write(knownEvent.getterName);
    } else {
      // Use on[name] instead
      buffer
        ..write("on['")
        ..write(handler.event)
        ..write("']");
    }

    if (handler.modifier.isNotEmpty) {
      // Transform the event stream to account for the modifiers.
      buffer.write('.withModifiers(');

      for (final modifier in handler.modifier) {
        switch (modifier) {
          case EventModifier.preventDefault:
            buffer.write('preventDefault: true,');
            break;
          case EventModifier.stopPropagation:
            buffer.write('stopPropagation: true,');
            break;
          case EventModifier.passive:
            buffer.write('passive: true,');
            break;
          case EventModifier.nonpassive:
            buffer.write('passive: false,');
            break;
          case EventModifier.capture:
            buffer.write('capture: true');
            break;
          case EventModifier.once:
            buffer.write('once: true,');
            break;
          case EventModifier.self:
            buffer.write('onlySelf: true,');
            break;
          case EventModifier.trusted:
            buffer.write('onlyTrusted: true,');
            break;
        }
      }

      buffer.write(')');
    }

    buffer.write('.listen(');
    callbackForEventHandler(handler, component);
    buffer.write(');');
  }

  void callbackForEventHandler(
      EventHandler handler, ComponentOrFragment component) {
    if (handler.isNoArgsListener) {
      // The handler does not take any arguments, so we have to wrap it in a
      // function that does.
      buffer.write('(_) {');
      writeDartWithPatchedReferences(handler.listener, component);
      buffer.write('();}');
    } else {
      // A tear-off will do
      writeDartWithPatchedReferences(handler.listener, component);
    }
  }

  void writePropertyAccessors() {
    for (final variable in component.dartDeclarations.values) {
      if (variable.isProp) {
        final element = variable.declaredElement;
        final type = element.type.getDisplayString(withNullability: true);
        final name = _nameForVar(variable);

        // int get foo => $$_v0;
        buffer
          ..write(type)
          ..write(' get ')
          ..write(element.name)
          ..write(' => ')
          ..write(name)
          ..writeln(';');

        if (!variable.isMutable) {
          // set foo (int value) {
          //   if (value != $$_v0) {
          //     $$_v0 = value;
          //     $invalidate(bitmask);
          //   }
          // }
          buffer
            ..writeln('set foo ($type value) {')
            ..writeln('  if (value != $name) {')
            ..writeln('    $name = value;')
            ..writeln('    \$invalidate(${variable.updateBitmask});')
            ..writeln('  }')
            ..writeln('}');
        }
      }
    }
  }

  void writeSetText(ReactiveText target, ComponentOrFragment component) {
    buffer
      ..write(_nameForNode(target))
      ..write('.zapText = ');

    final expression = target.expression;
    if (target.needsToString) {
      // Call .toString() on the result
      buffer.write('(');
      writeDartWithPatchedReferences(expression, component);
      buffer.write(').toString()');
    } else {
      // No .toString() call necessary, just embed the expression directly.
      writeDartWithPatchedReferences(expression, component);
    }

    buffer.writeln(';');
  }

  void writeUnchangedDartCode(AstNode node) {
    final source = prepareResult.temporaryDartFile
        .substring(node.offset, node.offset + node.length);
    buffer.write(source);
  }

  void writeDartWithPatchedReferences(
      AstNode dartCode, ComponentOrFragment component) {
    final originalCode = prepareResult.temporaryDartFile
        .substring(dartCode.offset, dartCode.offset + dartCode.length);
    final rewriter = _DartSourceRewriter(
        this, component is SubFragment, dartCode.offset, originalCode);
    dartCode.accept(rewriter);

    buffer.write(rewriter.content);
  }
}

class _DartSourceRewriter extends GeneralizingAstVisitor<void> {
  final Generator generator;
  final bool isInSubFragment;

  final int startOffsetInDart;
  int skew = 0;
  String content;

  _DartSourceRewriter(this.generator, this.isInSubFragment,
      this.startOffsetInDart, this.content);

  /// Replaces the range from [start] with length [originalLength] in the
  /// [content] string.
  ///
  /// The [skew] value is set accordingly so that [start] can refer to the
  /// original offset before making any changes. This only works when
  /// [_replaceRange] is called with increasing, non-overlapping offsets.
  void _replaceRange(int start, int originalLength, String newContent) {
    var actualStart = skew + start - startOffsetInDart;

    content = content.replaceRange(
        actualStart, actualStart + originalLength, newContent);
    skew += newContent.length - originalLength;
  }

  void _visitCompoundAssignmentExpression(CompoundAssignmentExpression node) {
    assert(!isInSubFragment);

    final target = node.writeElement;
    final variable = generator.component.dartDeclarations[target];
    final notifyUpdate = variable != null && variable.needsUpdateTracking;

    // Wrap the assignment in an $invalidateAssign block so that it can still
    // be used as an expression while also scheduling a node update!
    if (notifyUpdate) {
      final updateCode = variable!.updateBitmask;
      _replaceRange(node.offset, 0, '\$invalidateAssign($updateCode, ');
    }

    node.visitChildren(this);

    if (notifyUpdate) {
      _replaceRange(node.offset + node.length, 0, ')');
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _visitCompoundAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _visitCompoundAssignmentExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _visitCompoundAssignmentExpression(node);
  }

  @override
  void visitIdentifier(Identifier node) {
    final target = node.staticElement;
    if (target is VariableElement) {
      final variable = generator.component.dartDeclarations[target];
      if (variable != null) {
        var replacement =
            '${generator._nameForVar(variable)} /* ${node.name} */';

        if (isInSubFragment) {
          // Variables are stored on the main component, so prefix them with
          // _parent to reach it
          replacement = '$_parentField.$replacement';
        }

        _replaceRange(node.offset, node.length, replacement);
      }
    } else if (target is FunctionElement) {
      var newName = generator._nameForFunction(target);
      if (isInSubFragment) {
        newName = '$_parentField.$newName';
      }

      _replaceRange(node.offset, node.length, newName);
    } else if (target is ParameterElement) {
      if (target == generator.component.self) {
        _replaceRange(
            node.offset, node.length, isInSubFragment ? _parentField : 'this');
      }
    }
  }
}

extension on ReactiveNode {
  String? get dartTypeName {
    final $this = this;

    if ($this is ReactiveElement) {
      final known = $this.knownElement;
      return known != null ? '$_prefix.${known.className}' : '$_prefix.Element';
    } else if ($this is ReactiveText || $this is ConstantText) {
      return '$_prefix.Text';
    } else if ($this is SubComponent) {
      return $this.component.className;
    } else if ($this is ReactiveIf) {
      return '$_prefix.IfBlock';
    }
  }
}