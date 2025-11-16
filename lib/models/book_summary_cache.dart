import 'structured_summary.dart';

class BookSummaryCache {
  final String bookId;
  final int lastProcessedChunkIndex;
  final String cumulativeSummary;
  final DateTime lastUpdated;
  final int? lastSummaryViewChunkIndex; // Track where user was when they last viewed summary
  final int? lastProcessedWordIndex; // Track the last word index that was processed for summaries (legacy)
  final int? lastProcessedCharacterIndex; // Track the last character index that was processed for summaries
  final int? lastReadingStopChunkIndex; // Track where user stopped reading last time (chapter index)
  final int? lastReadingStopWordIndex; // Track where user stopped reading last time (word index, legacy)
  final int? lastReadingStopCharacterIndex; // Track where user stopped reading last time (character index)
  final DateTime? lastReadingStopTimestamp; // Track when user stopped reading last time
  final int? previousReadingStopChunkIndex; // Track where user stopped reading before that (chapter index, for "since last time")
  final int? previousReadingStopWordIndex; // Track where user stopped reading before that (word index, legacy)
  final int? previousReadingStopCharacterIndex; // Track where user stopped reading before that (character index, for "since last time")
  final DateTime? previousReadingStopTimestamp; // Track when user stopped reading before that
  final String? summarySinceLastTime; // Cached "since last time" summary
  final int? summarySinceLastTimeChunkIndex; // Chunk index when "since last time" summary was generated
  final int? summarySinceLastTimeWordIndex; // Word index when "since last time" summary was generated (legacy)
  final int? summarySinceLastTimeCharacterIndex; // Character index when "since last time" summary was generated
  final String? charactersSummary; // Cached characters summary
  final int? charactersSummaryChunkIndex; // Chunk index when characters summary was generated
  final int? charactersSummaryWordIndex; // Word index when characters summary was generated (legacy)
  final int? charactersSummaryCharacterIndex; // Character index when characters summary was generated
  final String? importantWords; // Cached important words table
  final String? generalSummaryJson; // Structured general summary payload
  final DateTime? generalSummaryUpdatedAt;
  final String? sinceLastTimeJson; // Structured since-last-time payload
  final DateTime? sinceLastTimeUpdatedAt;
  final String? characterProfilesJson; // Structured character profiles payload
  final DateTime? characterProfilesUpdatedAt;
  final String? readingInterruptionsJson; // JSON array of recent reading interruptions (last 5)
  final GeneralSummaryPayload? _generalSummary;
  final SinceLastTimePayload? _sinceLastTimePayload;
  final CharacterProfilesPayload? _characterProfilesPayload;

  BookSummaryCache({
    required this.bookId,
    required this.lastProcessedChunkIndex,
    required this.cumulativeSummary,
    required this.lastUpdated,
    this.lastSummaryViewChunkIndex,
    this.lastProcessedWordIndex,
    this.lastProcessedCharacterIndex,
    this.lastReadingStopChunkIndex,
    this.lastReadingStopWordIndex,
    this.lastReadingStopCharacterIndex,
    this.lastReadingStopTimestamp,
    this.previousReadingStopChunkIndex,
    this.previousReadingStopWordIndex,
    this.previousReadingStopCharacterIndex,
    this.previousReadingStopTimestamp,
    this.summarySinceLastTime,
    this.summarySinceLastTimeChunkIndex,
    this.summarySinceLastTimeWordIndex,
    this.summarySinceLastTimeCharacterIndex,
    this.charactersSummary,
    this.charactersSummaryChunkIndex,
    this.charactersSummaryWordIndex,
    this.charactersSummaryCharacterIndex,
    this.importantWords,
    this.generalSummaryJson,
    this.generalSummaryUpdatedAt,
    this.sinceLastTimeJson,
    this.sinceLastTimeUpdatedAt,
    this.characterProfilesJson,
    this.characterProfilesUpdatedAt,
    this.readingInterruptionsJson,
    GeneralSummaryPayload? generalSummary,
    SinceLastTimePayload? sinceLastTimePayload,
    CharacterProfilesPayload? characterProfilesPayload,
  })  : _generalSummary = generalSummary,
        _sinceLastTimePayload = sinceLastTimePayload,
        _characterProfilesPayload = characterProfilesPayload;

  GeneralSummaryPayload? get generalSummary =>
      _generalSummary ?? GeneralSummaryPayload.fromJsonString(generalSummaryJson);

  SinceLastTimePayload? get sinceLastTimePayload =>
      _sinceLastTimePayload ?? SinceLastTimePayload.fromJsonString(sinceLastTimeJson);

  CharacterProfilesPayload? get characterProfilesPayload =>
      _characterProfilesPayload ??
      CharacterProfilesPayload.fromJsonString(characterProfilesJson);

  Map<String, dynamic> toJson() {
    final generatedGeneralJson =
        generalSummaryJson ?? _generalSummary?.toJsonString();
    final generatedSinceLastTimeJson =
        sinceLastTimeJson ?? _sinceLastTimePayload?.toJsonString();
    final generatedCharacterProfilesJson =
        characterProfilesJson ?? _characterProfilesPayload?.toJsonString();

    return {
      'bookId': bookId,
      'lastProcessedChunkIndex': lastProcessedChunkIndex,
      'cumulativeSummary': cumulativeSummary,
      'lastUpdated': lastUpdated.toIso8601String(),
      'lastSummaryViewChunkIndex': lastSummaryViewChunkIndex,
      'lastProcessedWordIndex': lastProcessedWordIndex,
      'lastProcessedCharacterIndex': lastProcessedCharacterIndex,
      'lastReadingStopChunkIndex': lastReadingStopChunkIndex,
      'lastReadingStopWordIndex': lastReadingStopWordIndex,
      'lastReadingStopCharacterIndex': lastReadingStopCharacterIndex,
      'lastReadingStopTimestamp': lastReadingStopTimestamp?.toIso8601String(),
      'previousReadingStopChunkIndex': previousReadingStopChunkIndex,
      'previousReadingStopWordIndex': previousReadingStopWordIndex,
      'previousReadingStopCharacterIndex': previousReadingStopCharacterIndex,
      'previousReadingStopTimestamp': previousReadingStopTimestamp?.toIso8601String(),
      'summarySinceLastTime': summarySinceLastTime,
      'summarySinceLastTimeChunkIndex': summarySinceLastTimeChunkIndex,
      'summarySinceLastTimeWordIndex': summarySinceLastTimeWordIndex,
      'summarySinceLastTimeCharacterIndex': summarySinceLastTimeCharacterIndex,
      'charactersSummary': charactersSummary,
      'charactersSummaryChunkIndex': charactersSummaryChunkIndex,
      'charactersSummaryWordIndex': charactersSummaryWordIndex,
      'charactersSummaryCharacterIndex': charactersSummaryCharacterIndex,
      'importantWords': importantWords,
      'generalSummaryJson': generatedGeneralJson,
      'generalSummaryUpdatedAt': generalSummaryUpdatedAt?.toIso8601String(),
      'sinceLastTimeJson': generatedSinceLastTimeJson,
      'sinceLastTimeUpdatedAt': sinceLastTimeUpdatedAt?.toIso8601String(),
      'characterProfilesJson': generatedCharacterProfilesJson,
      'characterProfilesUpdatedAt': characterProfilesUpdatedAt?.toIso8601String(),
      'readingInterruptionsJson': readingInterruptionsJson,
    };
  }

  factory BookSummaryCache.fromJson(Map<String, dynamic> json) {
    return BookSummaryCache(
      bookId: json['bookId'] as String,
      lastProcessedChunkIndex: json['lastProcessedChunkIndex'] as int,
      cumulativeSummary: json['cumulativeSummary'] as String,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      lastSummaryViewChunkIndex: json['lastSummaryViewChunkIndex'] as int?,
      lastProcessedWordIndex: json['lastProcessedWordIndex'] as int?,
      lastProcessedCharacterIndex: json['lastProcessedCharacterIndex'] as int?,
      lastReadingStopChunkIndex: json['lastReadingStopChunkIndex'] as int?,
      lastReadingStopWordIndex: json['lastReadingStopWordIndex'] as int?,
      lastReadingStopCharacterIndex: json['lastReadingStopCharacterIndex'] as int?,
      lastReadingStopTimestamp: json['lastReadingStopTimestamp'] != null
          ? DateTime.parse(json['lastReadingStopTimestamp'] as String)
          : null,
      previousReadingStopChunkIndex: json['previousReadingStopChunkIndex'] as int?,
      previousReadingStopWordIndex: json['previousReadingStopWordIndex'] as int?,
      previousReadingStopCharacterIndex: json['previousReadingStopCharacterIndex'] as int?,
      previousReadingStopTimestamp: json['previousReadingStopTimestamp'] != null
          ? DateTime.parse(json['previousReadingStopTimestamp'] as String)
          : null,
      summarySinceLastTime: json['summarySinceLastTime'] as String?,
      summarySinceLastTimeChunkIndex: json['summarySinceLastTimeChunkIndex'] as int?,
      summarySinceLastTimeWordIndex: json['summarySinceLastTimeWordIndex'] as int?,
      summarySinceLastTimeCharacterIndex: json['summarySinceLastTimeCharacterIndex'] as int?,
      charactersSummary: json['charactersSummary'] as String?,
      charactersSummaryChunkIndex: json['charactersSummaryChunkIndex'] as int?,
      charactersSummaryWordIndex: json['charactersSummaryWordIndex'] as int?,
      charactersSummaryCharacterIndex: json['charactersSummaryCharacterIndex'] as int?,
      importantWords: json['importantWords'] as String?,
      generalSummaryJson: json['generalSummaryJson'] as String?,
      generalSummary: GeneralSummaryPayload.fromJsonString(
        json['generalSummaryJson'] as String?,
      ),
      generalSummaryUpdatedAt: json['generalSummaryUpdatedAt'] != null
          ? DateTime.parse(json['generalSummaryUpdatedAt'] as String)
          : null,
      sinceLastTimeJson: json['sinceLastTimeJson'] as String?,
      sinceLastTimePayload: SinceLastTimePayload.fromJsonString(
        json['sinceLastTimeJson'] as String?,
      ),
      sinceLastTimeUpdatedAt: json['sinceLastTimeUpdatedAt'] != null
          ? DateTime.parse(json['sinceLastTimeUpdatedAt'] as String)
          : null,
      characterProfilesJson: json['characterProfilesJson'] as String?,
      characterProfilesPayload: CharacterProfilesPayload.fromJsonString(
        json['characterProfilesJson'] as String?,
      ),
      characterProfilesUpdatedAt: json['characterProfilesUpdatedAt'] != null
          ? DateTime.parse(json['characterProfilesUpdatedAt'] as String)
          : null,
      readingInterruptionsJson: json['readingInterruptionsJson'] as String?,
    );
  }

  BookSummaryCache copyWith({
    String? bookId,
    int? lastProcessedChunkIndex,
    String? cumulativeSummary,
    DateTime? lastUpdated,
    int? lastSummaryViewChunkIndex,
    int? lastProcessedWordIndex,
    int? lastProcessedCharacterIndex,
    int? lastReadingStopChunkIndex,
    int? lastReadingStopWordIndex,
    int? lastReadingStopCharacterIndex,
    DateTime? lastReadingStopTimestamp,
    int? previousReadingStopChunkIndex,
    int? previousReadingStopWordIndex,
    int? previousReadingStopCharacterIndex,
    DateTime? previousReadingStopTimestamp,
    String? summarySinceLastTime,
    int? summarySinceLastTimeChunkIndex,
    int? summarySinceLastTimeWordIndex,
    int? summarySinceLastTimeCharacterIndex,
    String? charactersSummary,
    int? charactersSummaryChunkIndex,
    int? charactersSummaryWordIndex,
    int? charactersSummaryCharacterIndex,
    String? importantWords,
    String? generalSummaryJson,
    DateTime? generalSummaryUpdatedAt,
    GeneralSummaryPayload? generalSummary,
    String? sinceLastTimeJson,
    DateTime? sinceLastTimeUpdatedAt,
    SinceLastTimePayload? sinceLastTimePayload,
    String? characterProfilesJson,
    DateTime? characterProfilesUpdatedAt,
    CharacterProfilesPayload? characterProfilesPayload,
    String? readingInterruptionsJson,
  }) {
    return BookSummaryCache(
      bookId: bookId ?? this.bookId,
      lastProcessedChunkIndex:
          lastProcessedChunkIndex ?? this.lastProcessedChunkIndex,
      cumulativeSummary: cumulativeSummary ?? this.cumulativeSummary,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      lastSummaryViewChunkIndex: lastSummaryViewChunkIndex ?? this.lastSummaryViewChunkIndex,
      lastProcessedWordIndex: lastProcessedWordIndex ?? this.lastProcessedWordIndex,
      lastProcessedCharacterIndex: lastProcessedCharacterIndex ?? this.lastProcessedCharacterIndex,
      lastReadingStopChunkIndex: lastReadingStopChunkIndex ?? this.lastReadingStopChunkIndex,
      lastReadingStopWordIndex: lastReadingStopWordIndex ?? this.lastReadingStopWordIndex,
      lastReadingStopCharacterIndex: lastReadingStopCharacterIndex ?? this.lastReadingStopCharacterIndex,
      lastReadingStopTimestamp: lastReadingStopTimestamp ?? this.lastReadingStopTimestamp,
      previousReadingStopChunkIndex: previousReadingStopChunkIndex ?? this.previousReadingStopChunkIndex,
      previousReadingStopWordIndex: previousReadingStopWordIndex ?? this.previousReadingStopWordIndex,
      previousReadingStopCharacterIndex: previousReadingStopCharacterIndex ?? this.previousReadingStopCharacterIndex,
      previousReadingStopTimestamp: previousReadingStopTimestamp ?? this.previousReadingStopTimestamp,
      summarySinceLastTime: summarySinceLastTime ?? this.summarySinceLastTime,
      summarySinceLastTimeChunkIndex: summarySinceLastTimeChunkIndex ?? this.summarySinceLastTimeChunkIndex,
      summarySinceLastTimeWordIndex: summarySinceLastTimeWordIndex ?? this.summarySinceLastTimeWordIndex,
      summarySinceLastTimeCharacterIndex: summarySinceLastTimeCharacterIndex ?? this.summarySinceLastTimeCharacterIndex,
      charactersSummary: charactersSummary ?? this.charactersSummary,
      charactersSummaryChunkIndex: charactersSummaryChunkIndex ?? this.charactersSummaryChunkIndex,
      charactersSummaryWordIndex: charactersSummaryWordIndex ?? this.charactersSummaryWordIndex,
      charactersSummaryCharacterIndex: charactersSummaryCharacterIndex ?? this.charactersSummaryCharacterIndex,
      importantWords: importantWords ?? this.importantWords,
      generalSummaryJson: generalSummaryJson ?? this.generalSummaryJson,
      generalSummaryUpdatedAt: generalSummaryUpdatedAt ?? this.generalSummaryUpdatedAt,
      generalSummary: generalSummary ?? _generalSummary,
      sinceLastTimeJson: sinceLastTimeJson ?? this.sinceLastTimeJson,
      sinceLastTimeUpdatedAt: sinceLastTimeUpdatedAt ?? this.sinceLastTimeUpdatedAt,
      sinceLastTimePayload: sinceLastTimePayload ?? _sinceLastTimePayload,
      characterProfilesJson: characterProfilesJson ?? this.characterProfilesJson,
      characterProfilesUpdatedAt: characterProfilesUpdatedAt ?? this.characterProfilesUpdatedAt,
      characterProfilesPayload: characterProfilesPayload ?? _characterProfilesPayload,
      readingInterruptionsJson: readingInterruptionsJson ?? this.readingInterruptionsJson,
    );
  }
}

