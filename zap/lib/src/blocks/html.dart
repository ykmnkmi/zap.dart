import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:sanitize_dom/sanitize_dom.dart';
import 'package:web/web.dart';

import '../core/fragment.dart';

/// Inserts raw HTML into the document without any sanitization.
class HtmlTag extends Fragment {
  String? _rawHtml;

  /// An artificial element that we never insert into the document.
  ///
  /// We call `innerHtml` on this element to obtain the nodes that need to be
  /// inserted into the actual document.
  final Element _artificialParent = HTMLDivElement();
  Element? _mountTarget;
  Node? _mountAnchor;

  List<Node>? _children;

  HtmlTag([this._rawHtml]);

  set rawHtml(String html) {
    _rawHtml = html;

    // If this fragment has already been created, drop and re-add child nodes
    if (_mountTarget != null) {
      destroy();
      create(_mountTarget!, _mountAnchor);
    }
  }

  @override
  void create(Element target, [Node? anchor]) {
    _mountTarget = target;
    _mountAnchor = anchor;

    // ignore: unsafe_html
    _artificialParent.setInnerHtml(
      _rawHtml ?? '',
      treeSanitizer: NodeTreeSanitizer.trusted,
    );

    // [Element.children] is a view, but we want a fixed snapshot of the current
    // children, so copy.
    _children = JSArray.from<Node>(_artificialParent.childNodes).toDart;

    final children = _children;
    if (children != null) {
      for (final child in children) {
        target.insertBefore(child, anchor);
      }
    }
  }

  @override
  void update(int delta) {}

  @override
  void destroy() {
    final children = _children;
    if (children != null) {
      for (final child in children) {
        assert(child.has('remove'));
        (child as Element).remove();
      }
    }
    _children = null;
  }
}
