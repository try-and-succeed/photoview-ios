import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../state/library.dart';
import '../widgets/async_states.dart';
import '../widgets/media_grid.dart';

class PersonScreen extends ConsumerWidget {
  final FaceGroup faceGroup;

  const PersonScreen({super.key, required this.faceGroup});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(personMediaProvider(faceGroup.id));

    return Scaffold(
      appBar: AppBar(title: Text(faceGroup.label ?? 'Unlabeled')),
      body: media.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorMessage(
          message: '$error',
          onRetry: () => ref.invalidate(personMediaProvider(faceGroup.id)),
        ),
        data: (data) => data.isEmpty
            ? const EmptyMessage(message: 'No media for this person')
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    sliver: MediaSliverGrid(media: data),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
      ),
    );
  }
}
