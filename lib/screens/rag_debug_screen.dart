import 'package:flutter/material.dart';
import '../models/rag_chunk.dart';
import '../models/rag_index_progress.dart';
import '../models/book.dart';
import '../services/rag_database_service.dart';
import '../services/book_service.dart';

/// Debug screen to visualize RAG chunks and their text content
class RagDebugScreen extends StatefulWidget {
  const RagDebugScreen({super.key});

  @override
  State<RagDebugScreen> createState() => _RagDebugScreenState();
}

class _RagDebugScreenState extends State<RagDebugScreen> {
  final RagDatabaseService _ragDbService = RagDatabaseService();
  final BookService _bookService = BookService();
  
  List<Book> _books = [];
  Book? _selectedBook;
  RagIndexProgress? _indexStatus;
  List<RagChunk> _chunks = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final books = await _bookService.getAllBooks();
      setState(() {
        _books = books;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load books: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadChunksForBook(Book book) async {
    setState(() {
      _isLoading = true;
      _selectedBook = book;
      _chunks = [];
      _indexStatus = null;
      _error = null;
    });

    try {
      // Load index status
      final status = await _ragDbService.getIndexStatus(book.id);
      
      // Load all chunks
      final chunks = await _ragDbService.getChunks(book.id);
      
      // Get chunk count from database directly
      final chunkCount = await _ragDbService.getChunkCount(book.id);
      
      setState(() {
        _indexStatus = status;
        _chunks = chunks;
        _isLoading = false;
      });
      
      debugPrint('[RAG Debug] Loaded ${chunks.length} chunks for book ${book.title}');
      debugPrint('[RAG Debug] Database chunk count: $chunkCount');
      debugPrint('[RAG Debug] Index status: ${status?.status.name ?? "none"}, indexed: ${status?.indexedChunks ?? 0}/${status?.totalChunks ?? 0}');
      
      if (chunks.isNotEmpty) {
        final firstChunk = chunks.first;
        debugPrint('[RAG Debug] First chunk: charStart=${firstChunk.charStart}, charEnd=${firstChunk.charEnd}, text length=${firstChunk.text.length}, embedding dim=${firstChunk.embeddingDimension}');
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to load chunks: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RAG Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _selectedBook != null 
                ? () => _loadChunksForBook(_selectedBook!)
                : _loadBooks,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_selectedBook == null) {
      return _buildBookList();
    }

    return _buildChunkView();
  }

  Widget _buildBookList() {
    if (_books.isEmpty) {
      return const Center(
        child: Text('No books found. Import a book first.'),
      );
    }

    return ListView.builder(
      itemCount: _books.length,
      itemBuilder: (context, index) {
        final book = _books[index];
        return FutureBuilder<RagIndexProgress?>(
          future: _ragDbService.getIndexStatus(book.id),
          builder: (context, snapshot) {
            final status = snapshot.data;
            String subtitle = 'Loading...';
            if (snapshot.connectionState == ConnectionState.done) {
              if (status == null) {
                subtitle = 'Not indexed';
              } else {
                subtitle = 'Status: ${status.status.name}, '
                    'Chunks: ${status.indexedChunks}/${status.totalChunks}';
              }
            }
            
            return ListTile(
              title: Text(book.title),
              subtitle: Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _loadChunksForBook(book),
            );
          },
        );
      },
    );
  }

  Widget _buildChunkView() {
    return Column(
      children: [
        // Header with book info and status
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() {
                        _selectedBook = null;
                        _chunks = [];
                        _indexStatus = null;
                      });
                    },
                  ),
                  Expanded(
                    child: Text(
                      _selectedBook!.title,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildStatusInfo(),
            ],
          ),
        ),
        
        // Chunk list
        Expanded(
          child: _chunks.isEmpty
              ? const Center(
                  child: Text(
                    'No chunks found in database.\n\n'
                    'This means either:\n'
                    '1. The book has not been indexed yet\n'
                    '2. Indexing failed silently\n'
                    '3. Chunks are not being saved to the database',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: _chunks.length,
                  itemBuilder: (context, index) => _buildChunkCard(index),
                ),
        ),
      ],
    );
  }

  Widget _buildStatusInfo() {
    final status = _indexStatus;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Index Status: ${status?.status.name ?? "NOT INDEXED"}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: status?.isComplete == true ? Colors.green : Colors.orange,
          ),
        ),
        if (status != null) ...[
          Text('Total Chunks (expected): ${status.totalChunks}'),
          Text('Indexed Chunks (reported): ${status.indexedChunks}'),
          Text('Embedding Model: ${status.embeddingModel ?? "unknown"}'),
          Text('Embedding Dimension: ${status.embeddingDimension ?? "unknown"}'),
          if (status.errorMessage != null)
            Text(
              'Error: ${status.errorMessage}',
              style: const TextStyle(color: Colors.red),
            ),
        ],
        const SizedBox(height: 8),
        Text(
          'Chunks in Database: ${_chunks.length}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        if (_chunks.isNotEmpty) ...[
          Text('First chunk char range: ${_chunks.first.charStart}-${_chunks.first.charEnd}'),
          Text('Last chunk char range: ${_chunks.last.charStart}-${_chunks.last.charEnd}'),
          Text('First chunk embedding size: ${_chunks.first.embedding.length}'),
        ],
      ],
    );
  }

  Widget _buildChunkCard(int index) {
    final chunk = _chunks[index];
    final hasEmbedding = chunk.embedding.isNotEmpty;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ExpansionTile(
        title: Text(
          'Chunk $index',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'Chars: ${chunk.charStart}-${chunk.charEnd} | '
          'Tokens: ${chunk.tokenStart}-${chunk.tokenEnd} | '
          'Embedding: ${hasEmbedding ? "${chunk.embedding.length}d" : "MISSING!"}',
          style: TextStyle(
            fontSize: 12,
            color: hasEmbedding ? null : Colors.red,
          ),
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Metadata
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Chunk ID: ${chunk.chunkId}'),
                      Text('Chapter Index: ${chunk.chapterIndex ?? "N/A"}'),
                      Text('Character Range: ${chunk.charStart} - ${chunk.charEnd} (${chunk.charEnd - chunk.charStart} chars)'),
                      Text('Token Range: ${chunk.tokenStart} - ${chunk.tokenEnd} (${chunk.tokenEnd - chunk.tokenStart} tokens)'),
                      Text('Embedding Dimension: ${chunk.embeddingDimension}'),
                      Text('Actual Embedding Length: ${chunk.embedding.length}'),
                      if (hasEmbedding)
                        Text('Embedding sample: [${chunk.embedding.take(5).map((e) => e.toStringAsFixed(4)).join(", ")}...]'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Text content
                const Text(
                  'Text Content:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    chunk.text.isEmpty 
                        ? '[EMPTY TEXT - THIS IS A BUG!]'
                        : chunk.text,
                    style: TextStyle(
                      fontSize: 14,
                      color: chunk.text.isEmpty ? Colors.red : null,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Text length: ${chunk.text.length} characters',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
