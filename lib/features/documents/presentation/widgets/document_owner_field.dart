import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/documents/domain/entities/document.dart';
import 'package:submersion/features/documents/presentation/document_l10n.dart';
import 'package:submersion/features/documents/presentation/providers/document_owner_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// "Filed under": the record a document belongs to. Tapping asks for
/// another; a certification card is locked to its certification.
class DocumentOwnerField extends ConsumerWidget {
  final DocumentOwner owner;
  final bool locked;
  final VoidCallback onTap;

  const DocumentOwnerField({
    super.key = const ValueKey('document-owner-field'),
    required this.owner,
    required this.locked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final record = owner.isPersonal
        ? null
        : ref.watch(documentOwnerLabelProvider(owner)).value;
    // The record as the picker lists it, its kind shown by the icon: a
    // dive by its number, name or site, and date (#3391). The kind's own
    // label only when there is nothing to show (Personal).
    final units = UnitFormatter(ref.watch(settingsProvider));
    final text = record == null
        ? null
        : documentOwnerText(units, record.name, record.date);
    final shown = text ?? documentOwnerKindLabel(l10n, owner.kind);
    // Announced as a button: the field reads as text, but tapping it is
    // how a document is refiled.
    return Semantics(
      button: true,
      enabled: !locked,
      child: InkWell(
        onTap: locked ? null : onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: l10n.documents_detail_owner,
            prefixIcon: Icon(documentOwnerKindIcon(owner.kind)),
            helperText: locked ? l10n.documents_owner_locked : null,
            suffixIcon: Icon(
              locked ? Icons.lock_outline : Icons.arrow_drop_down,
            ),
          ),
          child: Text(shown),
        ),
      ),
    );
  }
}
