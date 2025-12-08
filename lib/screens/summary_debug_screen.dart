import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../models/book_summary_chunk.dart';
import '../services/enhanced_summary_service.dart';
import '../models/book.dart';

class SummaryDebugScreen extends StatefulWidget {
  final Book book;
  final EnhancedSummaryService enhancedSummaryService;

  const SummaryDebugScreen({
    super.key,
    required this.book,
    required this.enhancedSummaryService,
  });

  @override
  State<SummaryDebugScreen> createState() => _SummaryDebugScreenState();
}

class _SummaryDebugScreenState extends State<SummaryDebugScreen> {
  List<BookSummaryChunk> _chunks = [];
  bool _isLoading = true;
  final Map<int, bool> _showingSourceText = {};
  final Map<int, String> _sourceTexts = {};
  final Map<int, bool> _loadingSourceText = {};
  final Map<int, ScrollController> _sourceScrollControllers = {};

  @override
  void dispose() {
    for (final controller in _sourceScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadIntermediateSummaries();
  }

  Future<void> _loadIntermediateSummaries() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final chunks = await widget.enhancedSummaryService.getAllIntermediateSummaries(widget.book.id);
      setState(() {
        _chunks = chunks;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading intermediate summaries: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSourceText(int chunkIndex) async {
    final chunk = _chunks.firstWhere((c) => c.chunkIndex == chunkIndex);
    if (chunk.startCharacterIndex == null || chunk.endCharacterIndex == null) {
      return;
    }

    setState(() {
      _loadingSourceText[chunkIndex] = true;
    });

    try {
      final sourceText = await widget.enhancedSummaryService.extractTextForCharacterRange(
        widget.book,
        chunk.startCharacterIndex!,
        chunk.endCharacterIndex!,
      );
      setState(() {
        _sourceTexts[chunkIndex] = sourceText;
        _showingSourceText[chunkIndex] = true;
        _loadingSourceText[chunkIndex] = false;
      });
      _scrollSourceTextToEnd(chunkIndex);
    } catch (e) {
      debugPrint('Error loading source text for chunk $chunkIndex: $e');
      setState(() {
        _sourceTexts[chunkIndex] = 'Error loading source text: $e';
        _showingSourceText[chunkIndex] = true;
        _loadingSourceText[chunkIndex] = false;
      });
    }
  }

  void _toggleSourceText(int chunkIndex) {
    setState(() {
      final currentValue = _showingSourceText[chunkIndex] ?? false;
      _showingSourceText[chunkIndex] = !currentValue;
    });
    if (_showingSourceText[chunkIndex] == true) {
      _scrollSourceTextToEnd(chunkIndex);
    }
  }

  ScrollController _controllerForChunk(int chunkIndex) {
    return _sourceScrollControllers.putIfAbsent(
      chunkIndex,
      () => ScrollController(),
    );
  }

  void _scrollSourceTextToEnd(int chunkIndex) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _sourceScrollControllers[chunkIndex];
      if (controller != null && controller.hasClients) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F0),
      appBar: AppBar(
        title: const Text('Résumés intermédiaires (Debug)'),
        backgroundColor: const Color(0xFFF5F5F0),
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _chunks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text(
                      'Aucun résumé intermédiaire disponible.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16.0),
                  itemCount: _chunks.length,
                  itemBuilder: (context, index) {
                    final chunk = _chunks[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 16.0),
                      child: ExpansionTile(
                        title: Text(
                          'Chunk ${chunk.chunkIndex}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              'Caractères: ${chunk.startCharacterIndex ?? 'N/A'} - ${chunk.endCharacterIndex ?? 'N/A'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              'Créé: ${_formatDate(chunk.createdAt)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (chunk.tokenCount != null)
                              Text(
                                'Tokens estimés: ${chunk.tokenCount}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                        children: [
                          // Summary section
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Résumé:',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                MarkdownBody(
                                  data: chunk.summaryText,
                                  styleSheet: MarkdownStyleSheet(
                                    p: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          height: 1.6,
                                        ),
                                    h1: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                    h2: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                    h3: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                // Source text button
                                if (chunk.startCharacterIndex != null && chunk.endCharacterIndex != null)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          onPressed: _loadingSourceText[chunk.chunkIndex] == true
                                              ? null
                                              : () {
                                                  if (_sourceTexts.containsKey(chunk.chunkIndex)) {
                                                    _toggleSourceText(chunk.chunkIndex);
                                                  } else {
                                                    _loadSourceText(chunk.chunkIndex);
                                                  }
                                                },
                                          icon: _loadingSourceText[chunk.chunkIndex] == true
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child: CircularProgressIndicator(strokeWidth: 2),
                                                )
                                              : Icon(_showingSourceText[chunk.chunkIndex] == true
                                                  ? Icons.visibility_off
                                                  : Icons.visibility),
                                          label: Text(_loadingSourceText[chunk.chunkIndex] == true
                                              ? 'Chargement...'
                                              : (_showingSourceText[chunk.chunkIndex] == true
                                                  ? 'Masquer le texte source'
                                                  : 'Voir le texte source')),
                                        ),
                                      ),
                                    ],
                                  ),
                                // Source text display
                                if (_showingSourceText[chunk.chunkIndex] == true && _sourceTexts.containsKey(chunk.chunkIndex))
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 16),
                                      Text(
                                        'Texte source:',
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
                                          ),
                                        ),
                                        constraints: const BoxConstraints(maxHeight: 300),
                                        child: SingleChildScrollView(
                                          controller: _controllerForChunk(chunk.chunkIndex),
                                          child: Text(
                                            _sourceTexts[chunk.chunkIndex]!,
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                  fontFamily: 'monospace',
                                                  height: 1.4,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

