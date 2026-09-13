import 'package:flutter/material.dart';

import '../api/capabilities.dart';

class ErrorMessage extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorMessage({super.key, required this.message, this.onRetry});

  /// Chooses how to present [error], so a screen can hand over whatever it
  /// caught without having to know the difference.
  ///
  /// A server that simply does not have a feature yet is not a failure of the
  /// app or of the network, and offering "Retry" for it would be a lie — no
  /// number of retries adds a field to someone else's server.
  static Widget forError(Object error, {VoidCallback? onRetry}) {
    if (error is UnsupportedFieldException) {
      return EmptyMessage(
        message: error.message,
        icon: Icons.extension_off_outlined,
      );
    }

    return ErrorMessage(message: '$error', onRetry: onRetry);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyMessage extends StatelessWidget {
  final String message;
  final IconData icon;

  const EmptyMessage({
    super.key,
    required this.message,
    this.icon = Icons.photo_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
