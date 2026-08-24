import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// A single row of an [showAnchoredContextMenu] menu.
///
/// An item is either a leaf (activating it pops the whole menu stack with its
/// [id]) or a parent with [children] (activating it opens one submenu level).
/// The widget deliberately knows nothing about games, collections or any other
/// domain concept: callers build the item list and interpret the returned id.
class ContextMenuItem {
  /// Value returned by [showAnchoredContextMenu] when this leaf is activated.
  final String id;

  /// Already-localized row label. Nothing here goes through `AppLocale`, so the
  /// caller is responsible for translating before building the list.
  final String label;

  /// Optional leading glyph.
  final IconData? icon;

  /// Sub-items. A non-empty list turns this row into a submenu parent (only one
  /// level deep is supported: children of children are ignored).
  final List<ContextMenuItem> children;

  /// Draws a hairline above the row, to group it apart from the rows before it.
  final bool separatorBefore;

  /// Marks the row as the value currently in effect, drawing a trailing check.
  ///
  /// For rows that pick a setting rather than perform an action (view mode,
  /// card size), so the menu shows what is active the way the systems and
  /// game-view dropdowns do. Ignored on a submenu parent, whose trailing slot
  /// already carries the chevron.
  final bool selected;

  const ContextMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.children = const <ContextMenuItem>[],
    this.separatorBefore = false,
    this.selected = false,
  });

  bool get hasSubmenu => children.isNotEmpty;
}

/// Which edge of the anchor the panel hangs off.
enum ContextMenuAlignment {
  /// Panel starts just past the anchor's right edge. Right for a small anchor
  /// (an options button), where the menu should sit next to it.
  besideAnchor,

  /// Panel's left edge lines up with the anchor's. Right for a wide anchor (a
  /// full-width list row, a grid card), where [besideAnchor] would shove the
  /// panel to the far side of the screen and leave no room for a submenu.
  overAnchor,
}

/// Sentinel result meaning "the user asked to close the whole stack" (Y).
/// A submenu pops with it so the parent level closes itself too.
const String _dismissAllResult = '__context_menu_dismiss_all__';

/// Row metrics. Kept as constants so the menu box can be measured before it is
/// laid out — the viewport clamp/flip needs a height up front.
const double _kItemHeight = 30;
const double _kSeparatorHeight = 9;
const double _kVerticalPadding = 8;
const double _kAnchorGap = 6;
const double _kViewportMargin = 8;

/// Opens a gamepad-navigable context menu anchored to [anchorKey]'s widget.
///
/// Returns the [ContextMenuItem.id] of the activated leaf, or null when the
/// menu was dismissed. [anchorKey] may be null or unmounted — the menu then
/// falls back to the centre of the screen.
///
/// [initialIndex] pre-highlights a top-level row. When [openSubmenuAtIndex] is
/// given, that row's submenu is opened as soon as the menu appears, with
/// [initialSubmenuIndex] highlighted inside it, so a two-press shortcut
/// (open + activate) can land on a nested item.
///
/// Each level pushes its own [GamepadNavigationManager] layer ([layerId] /
/// [submenuLayerId]) and pops it in `dispose`, so app resume re-activates the
/// top-most menu rather than the screen buried under it.
Future<String?> showAnchoredContextMenu({
  required BuildContext context,
  required List<ContextMenuItem> items,
  GlobalKey? anchorKey,
  int initialIndex = 0,
  int? openSubmenuAtIndex,
  int initialSubmenuIndex = 0,
  double? width,
  ContextMenuAlignment alignment = ContextMenuAlignment.besideAnchor,
  String layerId = 'context_menu',
  String submenuLayerId = 'context_submenu',
}) async {
  if (items.isEmpty) return null;

  final Rect anchor = _resolveAnchorRect(anchorKey, context);

  final result = await showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: layerId,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return FadeTransition(
        opacity: animation,
        child: AnchoredContextMenu(
          items: items,
          anchorRect: anchor,
          initialIndex: initialIndex,
          openSubmenuAtIndex: openSubmenuAtIndex,
          initialSubmenuIndex: initialSubmenuIndex,
          width: width,
          alignment: alignment,
          layerId: layerId,
          submenuLayerId: submenuLayerId,
        ),
      );
    },
  );

  return result == _dismissAllResult ? null : result;
}

/// Global bounds of [anchorKey]'s render box, or a zero-size rect at the centre
/// of the screen when the key has no (attached) render object — which happens
/// when the anchored row has been scrolled out of the viewport.
Rect _resolveAnchorRect(GlobalKey? anchorKey, BuildContext context) {
  final Size screen = MediaQuery.of(context).size;
  final RenderObject? renderObject = anchorKey?.currentContext
      ?.findRenderObject();
  if (renderObject is RenderBox &&
      renderObject.attached &&
      renderObject.hasSize) {
    final Offset origin = renderObject.localToGlobal(Offset.zero);
    if (origin.dx.isFinite && origin.dy.isFinite) {
      return origin & renderObject.size;
    }
  }
  return Rect.fromCenter(
    center: Offset(screen.width / 2, screen.height / 2),
    width: 0,
    height: 0,
  );
}

/// The menu panel itself. Public so a caller can host it directly (e.g. in a
/// test), but the normal entry point is [showAnchoredContextMenu].
class AnchoredContextMenu extends StatefulWidget {
  final List<ContextMenuItem> items;

  /// Global bounds of the widget the menu hangs off.
  final Rect anchorRect;
  final int initialIndex;
  final int? openSubmenuAtIndex;
  final int initialSubmenuIndex;
  final double? width;
  final ContextMenuAlignment alignment;
  final String layerId;
  final String submenuLayerId;

  /// Whether this panel is a nested level rather than the root menu.
  ///
  /// Only a submenu closes on D-pad left: left is how the user walks back out
  /// of the level right walked into. At the root there is nothing to walk back
  /// to, and closing there made a stray left press dismiss the whole menu, so
  /// the root leaves left unbound — B (or a tap outside) is the way out.
  final bool isSubmenu;

  const AnchoredContextMenu({
    super.key,
    required this.items,
    required this.anchorRect,
    this.initialIndex = 0,
    this.openSubmenuAtIndex,
    this.initialSubmenuIndex = 0,
    this.width,
    this.alignment = ContextMenuAlignment.besideAnchor,
    this.layerId = 'context_menu',
    this.submenuLayerId = 'context_submenu',
    this.isSubmenu = false,
  });

  @override
  State<AnchoredContextMenu> createState() => _AnchoredContextMenuState();
}

class _AnchoredContextMenuState extends State<AnchoredContextMenu> {
  late final GamepadNavigation _gamepadNav;
  late int _selectedIndex;
  bool _submenuOpen = false;

  /// One key per row, used to anchor that row's submenu next to it.
  late final List<GlobalKey> _itemKeys;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
    _selectedIndex = widget.initialIndex.clamp(0, widget.items.length - 1);

    _gamepadNav = GamepadNavigation(
      // Short fixed lists: a held direction would just spin the cursor round.
      allowRepeat: false,
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onNavigateRight: _openSubmenuIfAny,
      // Root menu: left is inert (see [AnchoredContextMenu.isSubmenu]).
      onNavigateLeft: widget.isSubmenu ? _close : null,
      onSelectItem: _activate,
      onBack: _close,
      // Y is the button that opened the menu: pressing it again dismisses the
      // whole stack rather than toggling a level.
      onFavorite: _dismissAll,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Dismissed within its first frame (a second B, a tap outside during the
      // fade-in): dispose has already popped the layer, and pushing it now
      // would leave a dead layer on top of the stack eating every button.
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        widget.layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      final autoOpen = widget.openSubmenuAtIndex;
      if (autoOpen != null &&
          autoOpen >= 0 &&
          autoOpen < widget.items.length &&
          widget.items[autoOpen].hasSubmenu) {
        _openSubmenu(autoOpen, initialIndex: widget.initialSubmenuIndex);
      }
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(widget.layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  void _move(int delta) {
    if (widget.items.isEmpty) return;
    setState(() {
      _selectedIndex =
          (_selectedIndex + delta + widget.items.length) % widget.items.length;
    });
    SfxService().playNavSound();
  }

  void _close() {
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _dismissAll() {
    SfxService().playBackSound();
    Navigator.of(context).pop(_dismissAllResult);
  }

  void _openSubmenuIfAny() {
    if (widget.items[_selectedIndex].hasSubmenu) {
      _openSubmenu(_selectedIndex);
    }
  }

  void _activate() {
    final item = widget.items[_selectedIndex];
    if (item.hasSubmenu) {
      _openSubmenu(_selectedIndex);
      return;
    }
    SfxService().playEnterSound();
    Navigator.of(context).pop(item.id);
  }

  /// Opens [index]'s children as a second level, anchored to that row. The
  /// submenu owns its own nav layer; when it resolves with a leaf id (or the
  /// dismiss-all sentinel) this level closes too, so one activation always
  /// tears the whole stack down.
  Future<void> _openSubmenu(int index, {int initialIndex = 0}) async {
    if (_submenuOpen) return;
    final item = widget.items[index];
    if (!item.hasSubmenu) return;

    setState(() {
      _selectedIndex = index;
      _submenuOpen = true;
    });
    SfxService().playEnterSound();

    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: widget.submenuLayerId,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: AnchoredContextMenu(
            items: item.children,
            anchorRect: _resolveAnchorRect(_itemKeys[index], dialogContext),
            initialIndex: initialIndex,
            width: widget.width,
            layerId: widget.submenuLayerId,
            // One level only: a third level would reuse the same layer id.
            submenuLayerId: widget.submenuLayerId,
            isSubmenu: true,
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _submenuOpen = false);
    if (result != null) {
      Navigator.of(context).pop(result);
    }
  }

  /// Height the panel will occupy once laid out. Computed from the row metrics
  /// rather than measured, because the viewport clamp has to run before layout.
  double get _panelHeight {
    double height = _kVerticalPadding.r * 2;
    for (final item in widget.items) {
      if (item.separatorBefore) height += _kSeparatorHeight.r;
      height += _kItemHeight.r;
    }
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Size screen = MediaQuery.of(context).size;
    final double width = widget.width ?? 200.r;
    final double height = _panelHeight;
    final double margin = _kViewportMargin.r;
    final double gap = _kAnchorGap.r;

    // A row with children opens its submenu to the right, because right is the
    // button the user presses to open it. So the panel is not placed for its
    // own width but for the whole chain's: reserve a second panel beside it
    // whenever any row has a submenu, or the submenu flips back over the menu
    // that spawned it.
    final bool opensSubmenu = widget.items.any((item) => item.hasSubmenu);
    final double chainWidth = opensSubmenu ? width * 2 + gap : width;

    // [ContextMenuAlignment.overAnchor] starts the panel at the anchor's left
    // edge; [besideAnchor] hangs it off the right edge. A full-width list row
    // is metres wide, so hanging off its right edge would put the panel against
    // the far side of the screen with nothing but the margin left for a
    // submenu — which is what overAnchor exists to avoid.
    double left = widget.alignment == ContextMenuAlignment.overAnchor
        ? widget.anchorRect.left
        : widget.anchorRect.right + gap;

    // Flip to the anchor's other side when the panel itself overflows, then
    // pull it back far enough that the submenu fits too. Clamp last, so a very
    // wide card can never push the panel off the edge (the Steam Deck's
    // 1280x800 logical viewport is the tightest).
    if (left + width > screen.width - margin) {
      left = widget.anchorRect.left - width - gap;
    }
    if (left + chainWidth > screen.width - margin) {
      left = screen.width - margin - chainWidth;
    }
    final double maxLeft = (screen.width - width - margin).clamp(
      0.0,
      double.infinity,
    );
    left = left.clamp(margin.clamp(0.0, maxLeft), maxLeft);

    // Vertically: [besideAnchor] sits alongside the anchor, so it top-aligns
    // with it. [overAnchor] shares the anchor's column, so top-aligning would
    // bury the very row the menu was opened on — it drops below the anchor
    // instead, leaving the selected game's name readable above the panel.
    // Either way, flip to the anchor's other side when the panel would run
    // past the bottom, then clamp.
    double top = widget.alignment == ContextMenuAlignment.overAnchor
        ? widget.anchorRect.bottom + gap
        : widget.anchorRect.top;
    if (top + height > screen.height - margin) {
      top = widget.alignment == ContextMenuAlignment.overAnchor
          ? widget.anchorRect.top - height - gap
          : widget.anchorRect.bottom - height;
    }
    // An anchor taller than the room on either side of it puts both of the
    // above out of bounds, and the clamp below would then park the panel
    // against the top of the screen, attached to nothing — the systems
    // carousel's centred card is nearly the full viewport, so it landed on the
    // header. Centre it on the anchor instead: with the panel already sharing
    // the anchor's left edge, that is the one remaining position that still
    // reads as belonging to the card.
    if (top < margin) {
      top = widget.anchorRect.center.dy - height / 2;
    }
    final double maxTop = (screen.height - height - margin).clamp(
      0.0,
      double.infinity,
    );
    top = top.clamp(margin.clamp(0.0, maxTop), maxTop);

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: _kVerticalPadding.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildRows(theme),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRows(ThemeData theme) {
    final rows = <Widget>[];
    for (int i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (item.separatorBefore) {
        rows.add(
          Divider(
            height: _kSeparatorHeight.r,
            thickness: 1,
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        );
      }
      final bool isFocused = i == _selectedIndex;
      rows.add(
        SizedBox(
          key: _itemKeys[i],
          height: _kItemHeight.r,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4.r),
            child: InkWell(
              onTap: () {
                setState(() => _selectedIndex = i);
                _activate();
              },
              onHover: (hovering) {
                if (hovering && !_submenuOpen) {
                  setState(() => _selectedIndex = i);
                }
              },
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              borderRadius: BorderRadius.circular(8.r),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r),
                decoration: BoxDecoration(
                  color: isFocused
                      ? theme.colorScheme.primary.withValues(alpha: 0.15)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8.r),
                  border: isFocused
                      ? Border.all(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.3,
                          ),
                          width: 1,
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    if (item.icon != null) ...[
                      Icon(
                        item.icon,
                        size: 14.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.9,
                        ),
                      ),
                      SizedBox(width: 8.r),
                    ],
                    Expanded(
                      child: Text(
                        item.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.r,
                          fontWeight: isFocused
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (item.hasSubmenu)
                      Icon(
                        Symbols.chevron_right_rounded,
                        size: 14.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      )
                    else if (item.selected)
                      Icon(
                        Symbols.check_rounded,
                        size: 14.r,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return rows;
  }
}
