import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/rag_history_store.dart';

class RagHistoryScreen extends StatefulWidget {
  const RagHistoryScreen({super.key, required this.store});
  final RagHistoryStore store;
  @override
  State<RagHistoryScreen> createState() => _RagHistoryScreenState();
}

class _RagHistoryScreenState extends State<RagHistoryScreen> {
  late Future<List<Map<String, dynamic>>> _rows;
  String t(String en, String fr) =>
      Localizations.localeOf(context).languageCode == 'fr' ? fr : en;
  @override
  void initState() {
    super.initState();
    _rows = widget.store.list();
  }

  Future<void> _copy({String? id}) async {
    final data = await widget.store.export(conversationId: id);
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
    );
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Diagnostics copied', 'Diagnostics copiés'))),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('Recent conversations', 'Discussions récentes')),
      actions: [
        IconButton(
          tooltip: t(
            'Copy all diagnostics as JSON',
            'Copier tous les diagnostics en JSON',
          ),
          onPressed: () => _copy(),
          icon: const Icon(Icons.copy_all),
        ),
      ],
    ),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _rows,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(
            child: Text(
              t(
                'History could not be loaded',
                'Impossible de charger l’historique',
              ),
            ),
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final rows = snapshot.data!;
        if (rows.isEmpty)
          return Center(
            child: Text(
              t('No saved conversations', 'Aucune discussion enregistrée'),
            ),
          );
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            return ListTile(
              title: Text(row['title'] as String? ?? ''),
              subtitle: Text(
                DateTime.fromMillisecondsSinceEpoch(
                  row['updated'] as int,
                ).toLocal().toString(),
              ),
              onTap: () => Navigator.pop(context, row),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: t('Diagnostics', 'Diagnostics'),
                    icon: const Icon(Icons.timeline),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => _Diagnostics(
                          store: widget.store,
                          id: row['id'] as String,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t(
                      'Delete conversation',
                      'Supprimer la discussion',
                    ),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await widget.store.delete(row['id'] as String);
                      if (mounted) setState(() => _rows = widget.store.list());
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.store, required this.id});
  final RagHistoryStore store;
  final String id;
  @override
  Widget build(BuildContext context) {
    final fr = Localizations.localeOf(context).languageCode == 'fr';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: fr ? 'Copier en JSON' : 'Copy JSON',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: const JsonEncoder.withIndent(
                    '  ',
                  ).convert(await store.export(conversationId: id)),
                ),
              );
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      fr ? 'Diagnostics copiés' : 'Diagnostics copied',
                    ),
                  ),
                );
            },
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: store.export(conversationId: id),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final conversations = snapshot.data!['conversations'] as List;
          if (conversations.isEmpty) return const SizedBox.shrink();
          final events = conversations.first['events'] as List;
          return ListView.builder(
            itemCount: events.length,
            itemBuilder: (context, i) {
              final e = events[i] as Map;
              return ExpansionTile(
                title: Text(
                  '${e['type']} · ${e['stage'] ?? ''} ${e['round'] ?? ''}',
                ),
                subtitle: Text('${e['utc']} · ${e['elapsedMs'] ?? ''} ms'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(e),
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
