import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:memoreader/l10n/app_localizations.dart';

import '../models/book.dart';
import 'reader/html_blocks.dart';
import 'reader/reader_state.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book});

  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  ReaderState? _readerState;
  Size? _lastSize;
  double _fontSize = 18;
  bool _isLoading = true;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureReader();
  }

  void _configureReader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final mediaQuery = MediaQuery.of(context);
      final size = mediaQuery.size;
      final padding = mediaQuery.viewPadding;
      final pageWidth = size.width - 32;
      final pageHeight = size.height - padding.top - padding.bottom - kToolbarHeight - 32;
      if (_readerState == null || _lastSize != size) {
        _lastSize = size;
        _bootReader(pageWidth, pageHeight);
      }
    });
  }

  Future<void> _bootReader(double width, double height) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: _fontSize) ??
          TextStyle(fontSize: _fontSize, height: 1.5);
      final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
      final readerState = await ReaderState.create(
        book: widget.book,
        pageWidth: width,
        pageHeight: height,
        baseStyle: baseStyle,
        devicePixelRatio: devicePixelRatio,
      );
      if (!mounted) return;
      setState(() {
        _readerState = readerState;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _updateFont(double size) async {
    if (_readerState == null) return;
    final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: size) ??
        TextStyle(fontSize: size, height: 1.5);
    await _readerState!.updateLayout(
      maxWidth: _readerState!.pageWidth,
      maxHeight: _readerState!.pageHeight,
      style: baseStyle,
    );
    setState(() {
      _fontSize = size;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (_isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_error != null) {
            return Center(child: Text(_error!));
          }
          final reader = _readerState;
          if (reader == null) {
            return const SizedBox.shrink();
          }

          return AnimatedBuilder(
            animation: reader,
            builder: (context, _) {
              final page = reader.currentPage;
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Text(l10n.fontSize),
                        Expanded(
                          child: Slider(
                            min: 14,
                            max: 28,
                            value: _fontSize,
                            onChanged: (value) => _updateFont(value),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_left),
                          onPressed: reader.previousPage,
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right),
                          onPressed: reader.nextPage,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: page == null
                        ? Center(child: Text(l10n.noChaptersAvailable))
                        : _PageView(
                            page: page,
                            baseStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      fontSize: _fontSize,
                                      height: 1.5,
                                    ) ??
                                TextStyle(fontSize: _fontSize, height: 1.5),
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _PageView extends StatelessWidget {
  const _PageView({required this.page, required this.baseStyle});

  final PageResult page;
  final TextStyle baseStyle;

  @override
  Widget build(BuildContext context) {
    final blocks = page.blocks;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final block = blocks[index];
        final children = <Widget>[];
        if (block.spacingBefore > 0) {
          children.add(SizedBox(height: block.spacingBefore));
        }

        if (block is ParagraphBlock) {
          children.add(
            Text.rich(
              block.toInlineSpan(baseStyle),
              textAlign: block.alignment,
              softWrap: true,
            ),
          );
        } else if (block is HeaderBlock) {
          children.add(
            Text.rich(
              block.toInlineSpan(baseStyle),
              textAlign: block.alignment,
            ),
          );
        } else if (block is QuoteBlock) {
          children.add(
            Text.rich(
              block.toInlineSpan(baseStyle),
              textAlign: block.alignment,
            ),
          );
        } else if (block is ImageBlock) {
          children.add(
            SizedBox(
              width: double.infinity,
              child: block.bytes.isEmpty
                  ? const SizedBox.shrink()
                  : Image.memory(
                      Uint8List.fromList(block.bytes),
                      fit: BoxFit.contain,
                    ),
            ),
          );
        }

        if (block.spacingAfter > 0) {
          children.add(SizedBox(height: block.spacingAfter));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}
