import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/context_menu/anchored_context_menu.dart';

/// One membership bucket a game can belong to, as presented by the Y menu.
///
/// The menu itself is membership-agnostic: the caller supplies the buckets and
/// the callbacks that mutate them, so Favourites (backed by
/// `user_roms.is_favorite`) and, later, user collections can sit side by side
/// without the menu knowing the difference.
class GameContextMenuTarget {
  /// Stable identifier, unique within one menu (e.g. `favorites`).
  final String id;

  /// Already-localized display name.
  final String label;

  final IconData icon;

  /// Whether the game is currently in this bucket. Drives which submenu the
  /// target is listed under.
  final bool isMember;

  /// Adds the game to the bucket. Only called when [isMember] is false.
  final Future<void> Function() add;

  /// Removes the game from the bucket. Only called when [isMember] is true.
  final Future<void> Function() remove;

  const GameContextMenuTarget({
    required this.id,
    required this.label,
    required this.icon,
    required this.isMember,
    required this.add,
    required this.remove,
  });
}

const String _settingsId = 'settings';
const String _createId = 'create';
const String _addPrefix = 'add:';
const String _removePrefix = 'remove:';

/// Opens the per-game Y menu anchored to [anchorKey]'s widget.
///
/// The menu shows `Settings`, `Add to…` (every target the game is not in) and
/// `Remove from…` (every target it is in); a submenu that would be empty is
/// omitted entirely rather than greyed out. [preselectTargetId] pre-opens
/// whichever submenu holds that target and highlights it, so the pre-Y-menu
/// one-press action survives as two presses (Y, A).
///
/// [onCreateTarget] adds a trailing `New collection…` row to `Add to…`. It is
/// the seam collections plug into.
Future<void> showGameContextMenu({
  required BuildContext context,
  required List<GameContextMenuTarget> targets,
  required VoidCallback onSettings,
  GlobalKey? anchorKey,
  String? preselectTargetId,
  Future<void> Function()? onCreateTarget,
  String? createTargetLabel,
}) async {
  assert(
    onCreateTarget == null || createTargetLabel != null,
    'createTargetLabel is required when onCreateTarget is supplied',
  );
  final addTargets = targets.where((t) => !t.isMember).toList();
  final removeTargets = targets.where((t) => t.isMember).toList();

  final addChildren = <ContextMenuItem>[
    for (final target in addTargets)
      ContextMenuItem(
        id: '$_addPrefix${target.id}',
        label: target.label,
        icon: target.icon,
      ),
    if (onCreateTarget != null)
      ContextMenuItem(
        id: _createId,
        label: createTargetLabel ?? '',
        icon: Symbols.add_rounded,
        separatorBefore: addTargets.isNotEmpty,
      ),
  ];

  final removeChildren = <ContextMenuItem>[
    for (final target in removeTargets)
      ContextMenuItem(
        id: '$_removePrefix${target.id}',
        label: target.label,
        icon: target.icon,
      ),
  ];

  final items = <ContextMenuItem>[
    ContextMenuItem(
      id: _settingsId,
      label: AppLocale.gameSettings.getString(context),
      icon: Symbols.settings_rounded,
    ),
    if (addChildren.isNotEmpty)
      ContextMenuItem(
        id: 'add',
        label: AppLocale.addTo.getString(context),
        icon: Symbols.playlist_add_rounded,
        children: addChildren,
      ),
    if (removeChildren.isNotEmpty)
      ContextMenuItem(
        id: 'remove',
        label: AppLocale.removeFrom.getString(context),
        icon: Symbols.playlist_remove_rounded,
        children: removeChildren,
      ),
  ];

  // Pre-open the submenu that holds the preselected target so the old
  // one-press muscle memory becomes exactly two presses.
  int? openSubmenuAtIndex;
  int initialSubmenuIndex = 0;
  if (preselectTargetId != null) {
    final addIndex = addChildren.indexWhere(
      (c) => c.id == '$_addPrefix$preselectTargetId',
    );
    final removeIndex = removeChildren.indexWhere(
      (c) => c.id == '$_removePrefix$preselectTargetId',
    );
    if (addIndex >= 0) {
      openSubmenuAtIndex = items.indexWhere((i) => i.id == 'add');
      initialSubmenuIndex = addIndex;
    } else if (removeIndex >= 0) {
      openSubmenuAtIndex = items.indexWhere((i) => i.id == 'remove');
      initialSubmenuIndex = removeIndex;
    }
  }

  final result = await showAnchoredContextMenu(
    context: context,
    items: items,
    anchorKey: anchorKey,
    initialIndex: openSubmenuAtIndex ?? 0,
    openSubmenuAtIndex: openSubmenuAtIndex,
    initialSubmenuIndex: initialSubmenuIndex,
    layerId: 'game_context_menu',
    submenuLayerId: 'game_context_submenu',
  );

  if (result == null) return;

  if (result == _settingsId) {
    onSettings();
    return;
  }
  if (result == _createId) {
    await onCreateTarget?.call();
    return;
  }
  if (result.startsWith(_addPrefix)) {
    final target = _targetById(targets, result.substring(_addPrefix.length));
    if (target != null) await target.add();
    return;
  }
  if (result.startsWith(_removePrefix)) {
    final target = _targetById(targets, result.substring(_removePrefix.length));
    if (target != null) await target.remove();
  }
}

GameContextMenuTarget? _targetById(
  List<GameContextMenuTarget> targets,
  String id,
) {
  for (final target in targets) {
    if (target.id == id) return target;
  }
  return null;
}
