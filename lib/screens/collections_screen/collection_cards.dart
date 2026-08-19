import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/services/sfx_service.dart';

import '../../themes/corner_radii.dart';

/// Fallback tint for a collection that has no artwork and no stored colours,
/// matching the Collections virtual system's own palette.
const String kCollectionFallbackColor = '#7C4DFF';

/// Presents [collection] to the systems-card widgets.
///
/// Collections are not systems, but they are shown with the same card, so they
/// are handed to it as a [SystemInfo]: the artwork becomes the card background,
/// the name becomes both the title and the logo fallback text (there is no
/// `assets/images/logos/collection:<uuid>.webp`, so `SystemCard` falls through
/// to [SystemLogoFallback], which renders the name), and the game count feeds
/// the footer.
///
/// [imageVersion] must be `CollectionsProvider.imageVersion`: replacing the
/// artwork writes to the same path, so only a changing version busts the
/// `ValueKey` the card keys its `Image.file` on.
SystemInfo collectionToSystemInfo(
  CollectionModel collection, {
  required int imageVersion,
}) {
  return SystemInfo(
    title: collection.name,
    shortName: collection.name,
    folderName: '${SystemFolderNames.collectionPrefix}${collection.id}',
    numOfRoms: collection.gameCount,
    color1: collection.color1 ?? kCollectionFallbackColor,
    color2: collection.color2,
    customBackgroundPath: collection.imagePath,
    imageVersion: imageVersion,
  );
}

/// The trailing card of the collections browser: activating it creates a new
/// collection.
///
/// It cannot be a [SystemInfo] fed to `SystemCard` — that card always paints an
/// image (or a colour wash) plus a logo, and this one is deliberately an icon
/// and a label. The surrounding chrome is copied so the two sit flush in the
/// same grid.
class NewCollectionCard extends StatelessWidget {
  const NewCollectionCard({
    super.key,
    required this.label,
    required this.isSelected,
    this.onTap,
  });

  /// Already-localized caption ("New collection").
  final String label;

  /// Whether the grid's cursor is on this card. Only changes the tap sound —
  /// the focus ring is drawn by the grid, as it is for system cards.
  final bool isSelected;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radii = theme.extension<CornerRadii>();

    return Padding(
      padding: EdgeInsets.all(2.r),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: radii?.radiusExternal ?? BorderRadius.circular(14.r),
            border: Border.all(color: theme.colorScheme.outline, width: 1.r),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 4.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radii?.radiusInternal ?? BorderRadius.circular(9.r),
            child: InkWell(
              onTap: () {
                if (isSelected) {
                  SfxService().playEnterSound();
                } else {
                  SfxService().playNavSound();
                }
                onTap?.call();
              },
              canRequestFocus: false,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: Padding(
                padding: EdgeInsets.only(
                  top: 4.r,
                  bottom: 0.r,
                  left: 4.r,
                  right: 4.r,
                ),
                child: Column(
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius:
                            radii?.radiusInternal ?? BorderRadius.circular(9.r),
                        child: Container(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          child: Center(
                            child: Icon(
                              Symbols.add_rounded,
                              size: 64.r,
                              weight: 700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(horizontal: 4.r),
                        child: Text(
                          label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 10.r,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
