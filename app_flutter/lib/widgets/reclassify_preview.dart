import 'package:flutter/material.dart';

import '../api/models.dart';
import '../l10n/app_localizations.dart';
import 'face_move.dart' show describePerson;

/// How many people a preview names one by one before it sums up the rest.
const _namedDestinations = 5;

/// What a re-identification would do, from the server's dry run, with the
/// question whether to do it. True only for an explicit yes.
///
/// In words and numbers rather than a bare "continue?": a run can send
/// hundreds of faces elsewhere, and there is no undo on the server.
class ReclassifyPreviewDialog extends StatelessWidget {
  final ReclassifyResult result;

  /// The person whose faces are filed again, as the dialog names them.
  final String name;

  const ReclassifyPreviewDialog({
    super.key,
    required this.result,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final destinations = result.destinations;
    final named = destinations.take(_namedDestinations).toList();
    final others = destinations
        .skip(_namedDestinations)
        .fold(0, (sum, d) => sum + d.count);

    return AlertDialog(
      title: Text(l10n.personReclassifyTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.personReclassifyChecked(name, result.checked)),
            Text(l10n.personReclassifySamples(result.verifiedSamples)),
            const SizedBox(height: 12),
            Text(l10n.personReclassifyKept(name, result.kept)),
            Text(l10n.personReclassifyMoved(result.moved)),
            for (final d in named)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16),
                child: Text('${describePerson(d.person, l10n)}: ${d.count}'),
              ),
            if (others > 0)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 16),
                child: Text(l10n.personReclassifyOthers(others)),
              ),
            Text(l10n.personReclassifyUnmatched(result.unmatched)),
            if (result.conflicts > 0)
              Text(l10n.personReclassifyConflicts(result.conflicts)),
            const SizedBox(height: 12),
            Text(l10n.personReclassifyReview),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.personReclassifyAction),
        ),
      ],
    );
  }
}
