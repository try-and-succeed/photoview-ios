import 'package:flutter/material.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import '../util/formatting.dart';

/// The camera data of one photo as label/value rows. Nothing when there is
/// none to show.
///
/// Shared by the details sheet and the gallery's info panel, so a photo reads
/// the same in both.
class ExifTable extends StatelessWidget {
  final MediaExif exif;

  const ExifTable({super.key, required this.exif});

  @override
  Widget build(BuildContext context) {
    final rows = exifRows(exif, AppLocalizations.of(context));
    if (rows.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(
                      row.label,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(row.value, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
