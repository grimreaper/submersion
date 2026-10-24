import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Overflow-menu value of the site detail page's Duplicate action.
const kDuplicateSiteAction = 'duplicate';

/// The Duplicate row of the site detail menus (issue #3575).
PopupMenuItem<String> duplicateSiteMenuItem(BuildContext context) {
  return PopupMenuItem<String>(
    value: kDuplicateSiteAction,
    child: ListTile(
      leading: const Icon(Icons.copy),
      title: Text(context.l10n.diveSites_detail_duplicateMenu_label),
      contentPadding: EdgeInsets.zero,
    ),
  );
}

/// Opens the new-site form filled from [siteId], on top of the current
/// page. Nothing is written until the form is saved; Cancel returns here.
void openDuplicateSite(BuildContext context, String siteId) => context.push(
  Uri(path: '/sites/new', queryParameters: {'duplicateOf': siteId}).toString(),
);
