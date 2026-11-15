import 'rag_generation.dart';

String ragProgressLabel({
  required bool french,
  required RagStage stage,
  required int round,
  required Duration elapsed,
}) {
  final seconds = elapsed.inSeconds;
  if (stage == RagStage.generation)
    return french
        ? 'Rédaction de la réponse… · $seconds s'
        : 'Writing answer… · $seconds s';
  final steps = round > 0
      ? (french ? ' · Étapes $round/5' : ' · Steps $round/5')
      : '';
  return french
      ? 'Recherche…$steps · $seconds s'
      : 'Searching…$steps · $seconds s';
}
