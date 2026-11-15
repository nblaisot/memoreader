import 'package:flutter/material.dart';
import 'dart:async';
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
  Timer? _ticker;
  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

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
      if (p == null || p.isComplete) {
        _ticker?.cancel();
        _ticker = null;
        return const SizedBox.shrink();
      }
      final fr = Localizations.localeOf(context).languageCode == 'fr';
      final failed = p.hasError;
      final waiting = p.isWaiting;
      if (waiting && _ticker == null) {
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      } else if (!waiting) {
        _ticker?.cancel();
        _ticker = null;
      }
      final remaining =
          p.nextRetryAt?.difference(DateTime.now()).inSeconds ?? 0;
      final waitLabel = embeddingWaitLabel(
        p.waitReason,
        french: fr,
        remainingSeconds: remaining,
      );
      final actionLabel = switch (p.waitReason) {
        'quota' =>
          fr
              ? 'Préparation : vérifiez les crédits API'
              : 'Preparation: check API credits',
        'authentication' || 'authorization' =>
          fr
              ? 'Préparation : vérifiez les identifiants API'
              : 'Preparation: check API credentials',
        _ =>
          fr
              ? 'Préparation des questions : réessayer'
              : 'Question preparation: retry',
      };
      final label = waiting
          ? waitLabel
          : failed
          ? actionLabel
          : (fr ? 'Préparation des questions' : 'Preparing questions');
      return InkWell(
        onTap:
            failed ||
                (waiting &&
                    remaining <= 0 &&
                    !RagIndexingService().isIndexing(widget.bookId))
            ? () => RagIndexingService()
                  .startIndexing(widget.bookId)
                  .listen((_) {}, onError: (Object _) {})
            : null,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$label${!failed && !waiting && p.totalChunks > 0 ? ' ${p.progressPercentage.round()}%' : ''}',
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
