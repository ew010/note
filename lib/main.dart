import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const NotesApp());
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Notion Lite',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B3B3B)),
        useMaterial3: true,
      ),
      home: const NotesHomePage(),
    );
  }
}

class NotePage {
  NotePage({
    required this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
    required this.isFavorite,
  });

  final String id;
  String title;
  String content;
  DateTime updatedAt;
  bool isFavorite;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'updatedAt': updatedAt.toIso8601String(),
    'isFavorite': isFavorite,
  };

  static NotePage fromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled',
      content: json['content'] as String? ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }
}

class NotesHomePage extends StatefulWidget {
  const NotesHomePage({super.key});

  @override
  State<NotesHomePage> createState() => _NotesHomePageState();
}

class _NotesHomePageState extends State<NotesHomePage> {
  static const _storageKey = 'notion_lite_pages_v2';

  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _searchController = TextEditingController();

  final List<NotePage> _pages = [];

  String? _selectedPageId;
  bool _isLoading = true;
  bool _isHydratingEditor = false;
  bool _isPreviewMode = false;

  NotePage? get _selectedPage {
    if (_pages.isEmpty) {
      return null;
    }

    final current = _pages.where((p) => p.id == _selectedPageId).firstOrNull;
    return current ?? _visiblePages.firstOrNull;
  }

  List<NotePage> get _visiblePages {
    final q = _searchController.text.trim().toLowerCase();
    final filtered = _pages.where((p) {
      if (q.isEmpty) {
        return true;
      }
      return p.title.toLowerCase().contains(q) ||
          p.content.toLowerCase().contains(q);
    }).toList();

    filtered.sort((a, b) {
      if (a.isFavorite != b.isFavorite) {
        return a.isFavorite ? -1 : 1;
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });

    return filtered;
  }

  @override
  void initState() {
    super.initState();
    _titleController.addListener(_onEditorChanged);
    _contentController.addListener(_onEditorChanged);
    _searchController.addListener(_onSearchChanged);
    _loadPages();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);

    if (raw == null || raw.isEmpty) {
      _pages.add(
        NotePage(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          title: 'Welcome',
          content:
              '# Notion Lite\n\n- Use sidebar search\n- Pin important pages\n- Toggle Preview mode\n- Export and import JSON',
          updatedAt: DateTime.now(),
          isFavorite: true,
        ),
      );
      await _savePages();
    } else {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _pages
        ..clear()
        ..addAll(
          decoded
              .map((item) => NotePage.fromJson(item as Map<String, dynamic>))
              .toList(),
        );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isLoading = false;
      _selectedPageId = _visiblePages.firstOrNull?.id;
    });
    _syncEditorFromSelected();
  }

  Future<void> _savePages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(_pages.map((p) => p.toJson()).toList()),
    );
  }

  void _syncEditorFromSelected() {
    final page = _selectedPage;
    _isHydratingEditor = true;
    _titleController.text = page?.title ?? '';
    _contentController.text = page?.content ?? '';
    _isHydratingEditor = false;
  }

  void _onSearchChanged() {
    final visible = _visiblePages;
    if (visible.isEmpty) {
      setState(() {
        _selectedPageId = null;
      });
      _syncEditorFromSelected();
      return;
    }

    final stillVisible = visible.any((p) => p.id == _selectedPageId);
    if (!stillVisible) {
      setState(() {
        _selectedPageId = visible.first.id;
      });
      _syncEditorFromSelected();
    } else {
      setState(() {});
    }
  }

  void _onEditorChanged() {
    if (_isHydratingEditor) {
      return;
    }

    final page = _selectedPage;
    if (page == null) {
      return;
    }

    final nextTitle = _titleController.text.trim().isEmpty
        ? 'Untitled'
        : _titleController.text.trim();

    setState(() {
      page.title = nextTitle;
      page.content = _contentController.text;
      page.updatedAt = DateTime.now();
      _selectedPageId = page.id;
    });

    _savePages();
  }

  Future<void> _createPage() async {
    final page = NotePage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'Untitled',
      content: '',
      updatedAt: DateTime.now(),
      isFavorite: false,
    );

    setState(() {
      _pages.insert(0, page);
      _selectedPageId = page.id;
      _searchController.clear();
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  Future<void> _deleteSelectedPage() async {
    final page = _selectedPage;
    if (page == null || _pages.length == 1) {
      return;
    }

    setState(() {
      _pages.removeWhere((p) => p.id == page.id);
      _selectedPageId = _visiblePages.firstOrNull?.id;
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  Future<void> _toggleFavorite() async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }

    setState(() {
      page.isFavorite = !page.isFavorite;
      page.updatedAt = DateTime.now();
      _selectedPageId = page.id;
    });

    await _savePages();
  }

  Future<void> _copyAllAsJson() async {
    final data = jsonEncode(_pages.map((p) => p.toJson()).toList());
    await Clipboard.setData(ClipboardData(text: data));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('All notes copied as JSON')));
  }

  Future<void> _importFromJson() async {
    final inputController = TextEditingController();
    final imported = await showDialog<List<NotePage>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import JSON'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: inputController,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: 'Paste JSON exported from this app',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final decoded =
                      jsonDecode(inputController.text) as List<dynamic>;
                  final pages = decoded
                      .map(
                        (item) =>
                            NotePage.fromJson(item as Map<String, dynamic>),
                      )
                      .toList();
                  Navigator.of(context).pop(pages);
                } catch (_) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid JSON format')),
                  );
                }
              },
              child: const Text('Import'),
            ),
          ],
        );
      },
    );

    if (imported == null || imported.isEmpty) {
      return;
    }

    setState(() {
      _pages
        ..clear()
        ..addAll(imported);
      _selectedPageId = _visiblePages.firstOrNull?.id;
    });
    _syncEditorFromSelected();
    await _savePages();

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported ${imported.length} pages')),
    );
  }

  void _insertAtCursor(String text) {
    final value = _contentController.value;
    final selection = value.selection;
    final start = selection.start < 0 ? value.text.length : selection.start;
    final end = selection.end < 0 ? value.text.length : selection.end;

    final newText = value.text.replaceRange(start, end, text);
    final newOffset = start + text.length;

    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final selected = _selectedPage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notion Lite'),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: () => FocusScope.of(context).requestFocus(FocusNode()),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Preview',
            onPressed: () {
              setState(() {
                _isPreviewMode = !_isPreviewMode;
              });
            },
            icon: Icon(
              _isPreviewMode
                  ? Icons.edit_note_outlined
                  : Icons.preview_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Export JSON',
            onPressed: _copyAllAsJson,
            icon: const Icon(Icons.upload_file_outlined),
          ),
          IconButton(
            tooltip: 'Import JSON',
            onPressed: _importFromJson,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'New page',
            onPressed: _createPage,
            icon: const Icon(Icons.note_add_outlined),
          ),
          IconButton(
            tooltip: 'Delete page',
            onPressed: _pages.length > 1 ? _deleteSelectedPage : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Row(
        children: [
          Container(
            width: 310,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              border: Border(
                right: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Pages',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Create page',
                            onPressed: _createPage,
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                      TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: 'Search pages...',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _visiblePages.isEmpty
                      ? const Center(child: Text('No matching pages'))
                      : ListView.builder(
                          itemCount: _visiblePages.length,
                          itemBuilder: (context, index) {
                            final page = _visiblePages[index];
                            final isSelected = page.id == _selectedPageId;
                            return ListTile(
                              selected: isSelected,
                              leading: Icon(
                                page.isFavorite
                                    ? Icons.star_rounded
                                    : Icons.description_outlined,
                                color: page.isFavorite
                                    ? Colors.amber.shade700
                                    : null,
                              ),
                              title: Text(
                                page.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                _formatTime(page.updatedAt),
                                maxLines: 1,
                              ),
                              onTap: () {
                                setState(() {
                                  _selectedPageId = page.id;
                                });
                                _syncEditorFromSelected();
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          Expanded(
            child: selected == null
                ? const Center(child: Text('No page selected'))
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _titleController,
                                style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w700,
                                ),
                                decoration: const InputDecoration(
                                  hintText: 'Untitled',
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: selected.isFavorite ? 'Unpin' : 'Pin',
                              onPressed: _toggleFavorite,
                              icon: Icon(
                                selected.isFavorite
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                color: selected.isFavorite
                                    ? Colors.amber.shade700
                                    : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            ActionChip(
                              label: const Text('H1'),
                              onPressed: () => _insertAtCursor('\n# Heading\n'),
                            ),
                            ActionChip(
                              label: const Text('H2'),
                              onPressed: () =>
                                  _insertAtCursor('\n## Subheading\n'),
                            ),
                            ActionChip(
                              label: const Text('Todo'),
                              onPressed: () =>
                                  _insertAtCursor('\n- [ ] Task\n'),
                            ),
                            ActionChip(
                              label: const Text('Code'),
                              onPressed: () =>
                                  _insertAtCursor('\n```\ncode\n```\n'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _isPreviewMode
                              ? _MarkdownPreview(
                                  content: _contentController.text,
                                )
                              : TextField(
                                  controller: _contentController,
                                  expands: true,
                                  maxLines: null,
                                  minLines: null,
                                  keyboardType: TextInputType.multiline,
                                  textAlignVertical: TextAlignVertical.top,
                                  decoration: const InputDecoration(
                                    hintText:
                                        'Type markdown, use chips for quick insert',
                                    border: InputBorder.none,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    if (now.difference(time).inDays == 0) {
      final hour = time.hour.toString().padLeft(2, '0');
      final minute = time.minute.toString().padLeft(2, '0');
      return 'Today $hour:$minute';
    }
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}

class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final lines = content.split('\n');
    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.separated(
      itemCount: lines.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final line = lines[index];

        if (line.startsWith('### ')) {
          return Text(
            line.substring(4),
            style: Theme.of(context).textTheme.titleMedium,
          );
        }
        if (line.startsWith('## ')) {
          return Text(
            line.substring(3),
            style: Theme.of(context).textTheme.headlineSmall,
          );
        }
        if (line.startsWith('# ')) {
          return Text(
            line.substring(2),
            style: Theme.of(context).textTheme.headlineMedium,
          );
        }
        if (line.startsWith('- [ ] ')) {
          return Row(
            children: [
              const Icon(Icons.check_box_outline_blank, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(line.substring(6))),
            ],
          );
        }
        if (line.startsWith('- [x] ') || line.startsWith('- [X] ')) {
          return Row(
            children: [
              const Icon(Icons.check_box, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  line.substring(6),
                  style: const TextStyle(
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
              ),
            ],
          );
        }
        if (line.startsWith('- ')) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• '),
              Expanded(child: Text(line.substring(2))),
            ],
          );
        }
        if (line.trim().startsWith('```')) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(line.trim()),
          );
        }

        return Text(line);
      },
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
