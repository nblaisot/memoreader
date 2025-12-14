import 'structured_summary.dart';

class BookSummaryChunk {
  final String bookId;
  final int chunkIndex;
  final ChunkType chunkType;
  final String summaryText;
  final int? tokenCount;
  final DateTime createdAt;
  final String? eventsJson;
  final String? characterNotesJson;
  final int? startCharacterIndex;
  final int? endCharacterIndex;
  final String? contentHash;
  final String? sourceText; // Actual source text sent to LLM
  final List<SummaryEvent>? _events;
  final List<ChunkCharacterNote>? _characterNotes;

  BookSummaryChunk({
    required this.bookId,
    required this.chunkIndex,
    required this.chunkType,
    required this.summaryText,
    this.tokenCount,
    required this.createdAt,
    this.eventsJson,
    this.characterNotesJson,
    this.startCharacterIndex,
    this.endCharacterIndex,
    this.contentHash,
    this.sourceText,
    List<SummaryEvent>? events,
    List<ChunkCharacterNote>? characterNotes,
  })  : _events = events,
        _characterNotes = characterNotes;

  List<SummaryEvent>? get events {
    if (_events != null) return _events;
    return StructuredSummaryCodec.decodeEvents(eventsJson);
  }

  List<ChunkCharacterNote>? get characterNotes {
    if (_characterNotes != null) return _characterNotes;
    return StructuredSummaryCodec.decodeCharacterNotes(characterNotesJson);
  }

  Map<String, dynamic> toJson() {
    final eventsPayload = eventsJson ?? StructuredSummaryCodec.encodeEvents(_events);
    final characterNotesPayload = characterNotesJson ??
        StructuredSummaryCodec.encodeCharacterNotes(_characterNotes);
    return {
      'bookId': bookId,
      'chunkIndex': chunkIndex,
      'chunkType': chunkType.name,
      'summaryText': summaryText,
      'tokenCount': tokenCount,
      'createdAt': createdAt.toIso8601String(),
      'eventsJson': eventsPayload,
      'characterNotesJson': characterNotesPayload,
      'startCharacterIndex': startCharacterIndex,
      'endCharacterIndex': endCharacterIndex,
      'contentHash': contentHash,
      'sourceText': sourceText,
    };
  }

  factory BookSummaryChunk.fromJson(Map<String, dynamic> json) {
    return BookSummaryChunk(
      bookId: json['bookId'] as String,
      chunkIndex: json['chunkIndex'] as int,
      chunkType: ChunkType.values.firstWhere(
        (e) => e.name == json['chunkType'],
        orElse: () => ChunkType.chapter,
      ),
      summaryText: json['summaryText'] as String,
      tokenCount: json['tokenCount'] as int?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      eventsJson: json['eventsJson'] as String?,
      characterNotesJson: json['characterNotesJson'] as String?,
      startCharacterIndex: json['startCharacterIndex'] as int?,
      endCharacterIndex: json['endCharacterIndex'] as int?,
      contentHash: json['contentHash'] as String?,
      sourceText: json['sourceText'] as String?,
      events: StructuredSummaryCodec.decodeEvents(json['eventsJson'] as String?),
      characterNotes:
          StructuredSummaryCodec.decodeCharacterNotes(json['characterNotesJson'] as String?),
    );
  }
}

enum ChunkType {
  chapter,
  fixedBlock,
}

