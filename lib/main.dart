import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
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
      title: 'Notion Lite Local',
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
    this.parentId,
  });

  final String id;
  String title;
  String content;
  DateTime updatedAt;
  bool isFavorite;
  String? parentId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'updatedAt': updatedAt.toIso8601String(),
    'isFavorite': isFavorite,
    'parentId': parentId,
  };

  static NotePage fromJson(Map<String, dynamic> json) {
    final legacyBlocks = json['blocks'] as List<dynamic>?;
    var content = json['content'] as String? ?? '';

    if ((content.isEmpty) && legacyBlocks != null && legacyBlocks.isNotEmpty) {
      content = _blocksToMarkdown(legacyBlocks);
    }

    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled',
      content: content,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      isFavorite: json['isFavorite'] as bool? ?? false,
      parentId: json['parentId'] as String?,
    );
  }

  static String _blocksToMarkdown(List<dynamic> blocks) {
    final lines = <String>[];
    for (final item in blocks) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final type = item['type'] as String? ?? 'paragraph';
      final text = item['text'] as String? ?? '';
      final checked = item['checked'] as bool? ?? false;
      switch (type) {
        case 'heading':
          lines.add('# $text');
          break;
        case 'todo':
          lines.add('- [${checked ? 'x' : ' '}] $text');
          break;
        case 'code':
          lines.add('```');
          lines.add(text);
          lines.add('```');
          break;
        default:
          lines.add(text);
      }
      lines.add('');
    }
    return lines.join('\n').trim();
  }
}

class _PageNode {
  const _PageNode({required this.page, required this.depth});

  final NotePage page;
  final int depth;
}

class NotesHomePage extends StatefulWidget {
  const NotesHomePage({super.key});

  @override
  State<NotesHomePage> createState() => _NotesHomePageState();
}

class _NotesHomePageState extends State<NotesHomePage> {
  static const _storageKey = 'notion_lite_local_pages_v5';

  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _searchController = TextEditingController();
  final List<NotePage> _pages = [];

  String? _selectedPageId;
  bool _isLoading = true;
  bool _isHydratingEditor = false;
  int _mobileTabIndex = 0;
  bool _isPreviewMode = false;

  NotePage? get _selectedPage {
    if (_pages.isEmpty) {
      return null;
    }
    final current = _pages.where((p) => p.id == _selectedPageId).firstOrNull;
    return current ?? _visiblePageNodes.firstOrNull?.page;
  }

  List<_PageNode> get _visiblePageNodes {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      final filtered = _pages.where((p) {
        return p.title.toLowerCase().contains(q) ||
            p.content.toLowerCase().contains(q);
      }).toList();
      filtered.sort(_pageSort);
      return filtered
          .map((page) => _PageNode(page: page, depth: _depthOf(page)))
          .toList();
    }

    final childrenByParent = <String?, List<NotePage>>{};
    for (final page in _pages) {
      final parent = _pages.any((p) => p.id == page.parentId)
          ? page.parentId
          : null;
      childrenByParent.putIfAbsent(parent, () => []).add(page);
    }

    final roots = childrenByParent[null] ?? <NotePage>[];
    roots.sort(_pageSort);

    final nodes = <_PageNode>[];
    void walk(NotePage page, int depth) {
      nodes.add(_PageNode(page: page, depth: depth));
      final children = childrenByParent[page.id] ?? <NotePage>[];
      children.sort(_pageSort);
      for (final child in children) {
        walk(child, depth + 1);
      }
    }

    for (final root in roots) {
      walk(root, 0);
    }
    return nodes;
  }

  int _depthOf(NotePage page) {
    var depth = 0;
    var current = page;
    final seen = <String>{page.id};
    while (current.parentId != null) {
      final parent = _pages.where((p) => p.id == current.parentId).firstOrNull;
      if (parent == null || seen.contains(parent.id)) {
        break;
      }
      depth += 1;
      seen.add(parent.id);
      current = parent;
    }
    return depth;
  }

  int _pageSort(NotePage a, NotePage b) {
    if (a.isFavorite != b.isFavorite) {
      return a.isFavorite ? -1 : 1;
    }
    return b.updatedAt.compareTo(a.updatedAt);
  }

  List<String> _collectSubtreeIds(String pageId) {
    final result = <String>{pageId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final p in _pages) {
        if (!result.contains(p.id) &&
            p.parentId != null &&
            result.contains(p.parentId)) {
          result.add(p.id);
          changed = true;
        }
      }
    }
    return result.toList();
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
          content: '# Markdown Note\n\n现在是纯 Markdown 笔记。',
          updatedAt: DateTime.now(),
          isFavorite: true,
          parentId: null,
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
      _selectedPageId = _visiblePageNodes.firstOrNull?.page.id;
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
    final visible = _visiblePageNodes;
    if (visible.isEmpty) {
      setState(() {
        _selectedPageId = null;
      });
      _syncEditorFromSelected();
      return;
    }

    if (!visible.any((n) => n.page.id == _selectedPageId)) {
      setState(() {
        _selectedPageId = visible.first.page.id;
      });
      _syncEditorFromSelected();
      return;
    }

    setState(() {});
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
      parentId: null,
    );

    setState(() {
      _pages.insert(0, page);
      _selectedPageId = page.id;
      _searchController.clear();
      _mobileTabIndex = 1;
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  Future<void> _createChildPage() async {
    final parent = _selectedPage;
    if (parent == null) {
      await _createPage();
      return;
    }

    final page = NotePage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'Untitled',
      content: '',
      updatedAt: DateTime.now(),
      isFavorite: false,
      parentId: parent.id,
    );

    setState(() {
      _pages.add(page);
      _selectedPageId = page.id;
      _searchController.clear();
      _mobileTabIndex = 1;
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  Future<void> _deleteSelectedPage() async {
    final page = _selectedPage;
    if (page == null || _pages.length == 1) {
      return;
    }

    final removingIds = _collectSubtreeIds(page.id);
    if (removingIds.length == _pages.length) {
      return;
    }

    setState(() {
      _pages.removeWhere((p) => removingIds.contains(p.id));
      _selectedPageId = _visiblePageNodes.firstOrNull?.page.id;
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
    });

    await _savePages();
  }

  Future<void> _copyAllAsJson() async {
    final data = jsonEncode(_pages.map((p) => p.toJson()).toList());
    await Clipboard.setData(ClipboardData(text: data));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Local backup JSON copied to clipboard')),
    );
  }

  Future<void> _importFromJson() async {
    final inputController = TextEditingController();
    final imported = await showDialog<List<NotePage>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import Local Backup JSON'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: inputController,
              maxLines: 12,
              decoration: const InputDecoration(
                hintText: 'Paste backup JSON',
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
      _selectedPageId = _visiblePageNodes.firstOrNull?.page.id;
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

  Future<void> _exportCurrentPageMarkdown() async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }
    await _shareExportContent(
      content: '# ${page.title}\n\n${page.content}\n',
      fileName: '${_safeFileName(page.title)}.md',
      mimeType: 'text/markdown',
      successMessage: 'Markdown exported',
      webFallbackMessage: 'Markdown copied to clipboard',
    );
  }

  Future<void> _exportAllPagesJson() async {
    final jsonData = const JsonEncoder.withIndent(
      '  ',
    ).convert(_pages.map((p) => p.toJson()).toList());
    await _shareExportContent(
      content: jsonData,
      fileName:
          'notion-lite-export-${DateTime.now().millisecondsSinceEpoch}.json',
      mimeType: 'application/json',
      successMessage: 'JSON exported',
      webFallbackMessage: 'JSON copied to clipboard',
    );
  }

  Future<void> _shareExportContent({
    required String content,
    required String fileName,
    required String mimeType,
    required String successMessage,
    required String webFallbackMessage,
  }) async {
    try {
      if (kIsWeb) {
        await Clipboard.setData(ClipboardData(text: content));
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(webFallbackMessage)));
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsString(content);

      await Share.shareXFiles([
        XFile(file.path, mimeType: mimeType),
      ], text: 'Exported from Notion Lite Local');

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  String _safeFileName(String raw) {
    final normalized = raw.trim().isEmpty ? 'untitled' : raw.trim();
    return normalized.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '-');
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 900;
        if (isMobile) {
          return _buildMobileLayout(context);
        }
        return _buildDesktopLayout(context);
      },
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    final selected = _selectedPage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notion Lite Local'),
        actions: [
          _exportMenu(),
          IconButton(
            tooltip: _isPreviewMode ? 'Edit mode' : 'Markdown preview',
            onPressed: () {
              setState(() {
                _isPreviewMode = !_isPreviewMode;
              });
            },
            icon: Icon(
              _isPreviewMode
                  ? Icons.edit_note_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          IconButton(
            tooltip: 'New page',
            onPressed: _createPage,
            icon: const Icon(Icons.note_add_outlined),
          ),
          IconButton(
            tooltip: 'New subpage',
            onPressed: _createChildPage,
            icon: const Icon(Icons.subdirectory_arrow_right),
          ),
        ],
      ),
      body: _mobileTabIndex == 0
          ? _buildPagesPane(compact: true)
          : _buildEditorPane(selected, compact: true),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _mobileTabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _mobileTabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            label: 'Pages',
          ),
          NavigationDestination(
            icon: Icon(Icons.edit_note_outlined),
            label: 'Editor',
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    final selected = _selectedPage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notion Lite Local'),
        actions: [
          _exportMenu(),
          IconButton(
            tooltip: _isPreviewMode ? 'Edit mode' : 'Markdown preview',
            onPressed: () {
              setState(() {
                _isPreviewMode = !_isPreviewMode;
              });
            },
            icon: Icon(
              _isPreviewMode
                  ? Icons.edit_note_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Backup JSON',
            onPressed: _copyAllAsJson,
            icon: const Icon(Icons.upload_file_outlined),
          ),
          IconButton(
            tooltip: 'Restore JSON',
            onPressed: _importFromJson,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'New page',
            onPressed: _createPage,
            icon: const Icon(Icons.note_add_outlined),
          ),
          IconButton(
            tooltip: 'New subpage',
            onPressed: _createChildPage,
            icon: const Icon(Icons.subdirectory_arrow_right),
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
          SizedBox(width: 320, child: _buildPagesPane(compact: false)),
          Expanded(child: _buildEditorPane(selected, compact: false)),
        ],
      ),
    );
  }

  Widget _exportMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Export notes',
      onSelected: (value) {
        if (value == 'md') {
          _exportCurrentPageMarkdown();
        } else if (value == 'json') {
          _exportAllPagesJson();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'md', child: Text('Export current as Markdown')),
        PopupMenuItem(value: 'json', child: Text('Export all as JSON')),
      ],
      icon: const Icon(Icons.ios_share_outlined),
    );
  }

  Widget _buildPagesPane({required bool compact}) {
    return Container(
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
                    IconButton(
                      tooltip: 'Create subpage',
                      onPressed: _createChildPage,
                      icon: const Icon(Icons.call_split),
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
            child: _visiblePageNodes.isEmpty
                ? const Center(child: Text('No matching pages'))
                : ListView.builder(
                    itemCount: _visiblePageNodes.length,
                    itemBuilder: (context, index) {
                      final node = _visiblePageNodes[index];
                      final page = node.page;
                      final isSelected = page.id == _selectedPageId;
                      return ListTile(
                        selected: isSelected,
                        leading: SizedBox(
                          width: 14 + (node.depth * 14).toDouble(),
                          child: node.depth > 0
                              ? Icon(
                                  Icons.subdirectory_arrow_right,
                                  size: 14,
                                  color: Theme.of(context).colorScheme.outline,
                                )
                              : const SizedBox.shrink(),
                        ),
                        title: Row(
                          children: [
                            Icon(
                              page.isFavorite
                                  ? Icons.star_rounded
                                  : Icons.description_outlined,
                              size: 16,
                              color: page.isFavorite
                                  ? Colors.amber.shade700
                                  : null,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                page.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          _formatTime(page.updatedAt),
                          maxLines: 1,
                        ),
                        onTap: () {
                          setState(() {
                            _selectedPageId = page.id;
                            if (compact) {
                              _mobileTabIndex = 1;
                            }
                          });
                          _syncEditorFromSelected();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorPane(NotePage? selected, {required bool compact}) {
    if (selected == null) {
      return const Center(child: Text('No page selected'));
    }

    return Padding(
      padding: EdgeInsets.all(compact ? 12 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _titleController,
                  style: TextStyle(
                    fontSize: compact ? 26 : 34,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Untitled',
                    border: InputBorder.none,
                  ),
                ),
              ),
              if (compact)
                IconButton(
                  tooltip: 'Back to pages',
                  onPressed: () {
                    setState(() {
                      _mobileTabIndex = 0;
                    });
                  },
                  icon: const Icon(Icons.list_alt_outlined),
                ),
              IconButton(
                tooltip: selected.isFavorite ? 'Unpin' : 'Pin',
                onPressed: _toggleFavorite,
                icon: Icon(
                  selected.isFavorite
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: selected.isFavorite ? Colors.amber.shade700 : null,
                ),
              ),
              if (compact)
                IconButton(
                  tooltip: 'Delete page',
                  onPressed: _pages.length > 1 ? _deleteSelectedPage : null,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isPreviewMode
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Markdown(data: selected.content, selectable: true),
                  )
                : TextField(
                    controller: _contentController,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(height: 1.5),
                    decoration: const InputDecoration(
                      hintText:
                          'Write markdown here...\\n\\n# Title\\n- list\\n```code```',
                      border: InputBorder.none,
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
      final h = time.hour.toString().padLeft(2, '0');
      final m = time.minute.toString().padLeft(2, '0');
      return 'Today $h:$m';
    }
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
