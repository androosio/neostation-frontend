import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../l10n/app_locale.dart';

/// Localized "N Games" / "1 Game" labels for cards, footers and headers.
///
/// Two things these exist to stop callers doing by hand:
///
/// * **Interpolating, not concatenating.** `'$count ${AppLocale.games…}'` reads
///   fine in English and wrong in several shipped languages — ru puts the
///   number last (`Игр: 3`) and ko puts it mid-phrase (`컬렉션 3개`). The number
///   has to go into a translated template, so there is no translated bare noun
///   to concatenate and none of these helpers exposes one.
/// * **Choosing the form.** A count of exactly one is common enough to be worth
///   getting right — a first collection, a system with one ROM — and
///   "1 Games" is the kind of thing that reads as a bug.
///
/// The singular/plural split is binary, which is exact for a one-vs-many plural
/// rule and approximate otherwise: ru has a third form for 5+ that the plural
/// key carries, so ru is right at 1 and at 5+ and slightly off at 2-4. Better
/// than the always-plural this replaces; a real fix means per-language plural
/// rules, which this codebase's map-based l10n has no mechanism for.
String _label(BuildContext context, int count, String one, String many) =>
    (count == 1 ? one : many)
        .getString(context)
        .replaceFirst('{count}', '$count');

/// "12 Games" / "1 Game".
String gamesCountLabel(BuildContext context, int count) =>
    _label(context, count, AppLocale.gameCount, AppLocale.gamesCount);

/// "12 Apps" / "1 App".
String appsCountLabel(BuildContext context, int count) =>
    _label(context, count, AppLocale.appCount, AppLocale.appsCount);

/// "12 Tracks" / "1 Track".
String tracksCountLabel(BuildContext context, int count) =>
    _label(context, count, AppLocale.trackCount, AppLocale.tracksCount);

/// "12 Collections" / "1 Collection".
String collectionsCountLabel(BuildContext context, int count) => _label(
  context,
  count,
  AppLocale.collectionCount,
  AppLocale.collectionsCount,
);
