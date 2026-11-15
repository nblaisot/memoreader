import 'package:flutter/material.dart';
import '../models/rag_index_progress.dart';
import '../services/rag_indexing_service.dart';

class RagPreparationStatus extends StatefulWidget {
  const RagPreparationStatus({
    super.key,
    required this.bookId,
    this.onDarkBackground = false,
  });
  final String bookId;
  final bool onDarkBackground;
  @override
  State<RagPreparationStatus> createState() => _RagPreparationStatusState();
}

class _RagPreparationStatusState extends State<RagPreparationStatus> {
  late Stream<RagIndexProgress> _progress;
  @override
  void initState() {
    super.initState();
    _progress = RagIndexingService().observe(widget.bookId);
  }

  @override
  void didUpdateWidget(covariant RagPreparationStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      _progress = RagIndexingService().observe(widget.bookId);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<RagIndexProgress>(
    stream: _progress,
    initialData: RagIndexingService().snapshot(widget.bookId),
    builder: (context, snapshot) {
      final p = snapshot.data;
      if (p == null || p.isComplete) return const SizedBox.shrink();
      final fr = Localizations.localeOf(context).languageCode == 'fr';
      final failed = p.hasError;
      final label = failed
          ? (fr
                ? 'Préparation des questions : réessayer'
                : 'Question preparation: retry')
          : (fr ? 'Préparation des questions' : 'Preparing questions');
      return InkWell(
        onTap: failed
            ? () => RagIndexingService()
                  .startIndexing(widget.bookId)
                  .listen((_) {}, onError: (Object _) {})
            : null,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$label${!failed && p.totalChunks > 0 ? ' ${p.progressPercentage.round()}%' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: widget.onDarkBackground
                  ? Colors.white70
                  : Theme.of(context).colorScheme.secondary,
            ),
          ),
        ),
      );
    },
  );
}
