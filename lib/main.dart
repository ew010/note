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

enum BlockType { paragraph, heading, todo, code }

enum BlockTone { normal, red, orange, green, blue, purple }

class NoteBlock {
  NoteBlock({
    required this.id,
    required this.type,
    required this.text,
    this.checked = false,
    this.tone = BlockTone.normal,
  });

  final String id;
  BlockType type;
  String text;
  bool checked;
  BlockTone tone;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'text': text,
    'checked': checked,
    'tone': tone.name,
  };

  static NoteBlock fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'paragraph';
    final type = BlockType.values.firstWhere(
      (item) => item.name == typeStr,
      orElse: () => BlockType.paragraph,
    );
    final toneStr = json['tone'] as String? ?? 'normal';
    final tone = BlockTone.values.firstWhere(
      (item) => item.name == toneStr,
      orElse: () => BlockTone.normal,
    );
    return NoteBlock(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      text: json['text'] as String? ?? '',
      checked: json['checked'] as bool? ?? false,
      tone: tone,
    );
  }
}

class NotePage {
  NotePage({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.isFavorite,
    required this.blocks,
    this.parentId,
  });

  final String id;
  String title;
  DateTime updatedAt;
  bool isFavorite;
  List<NoteBlock> blocks;
  String? parentId;

  String get searchText => blocks.map((b) => b.text).join('\n');

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt.toIso8601String(),
    'isFavorite': isFavorite,
    'blocks': blocks.map((b) => b.toJson()).toList(),
    'parentId': parentId,
  };

  static NotePage fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['blocks'] as List<dynamic>?;
    List<NoteBlock> blocks;

    if (rawBlocks != null && rawBlocks.isNotEmpty) {
      blocks = rawBlocks
          .map((item) => NoteBlock.fromJson(item as Map<String, dynamic>))
          .toList();
    } else {
      final oldContent = json['content'] as String? ?? '';
      final lines = oldContent.split('\n');
      blocks = lines
          .map(
            (line) => NoteBlock(
              id: '${DateTime.now().microsecondsSinceEpoch}-${line.hashCode}',
              type: BlockType.paragraph,
              text: line,
            ),
          )
          .toList();
      if (blocks.isEmpty) {
        blocks = [_defaultBlock()];
      }
    }

    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      isFavorite: json['isFavorite'] as bool? ?? false,
      blocks: blocks,
      parentId: json['parentId'] as String?,
    );
  }

  static NoteBlock _defaultBlock() {
    return NoteBlock(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: BlockType.paragraph,
      text: '',
    );
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
  static const _storageKey = 'notion_lite_local_pages_v4';

  final _titleController = TextEditingController();
  final _searchController = TextEditingController();
  final List<NotePage> _pages = [];

  String? _selectedPageId;
  bool _isLoading = true;
  bool _isHydratingTitle = false;
  int _mobileTabIndex = 0;
  bool _isMarkdownPreview = false;

  final Map<String, TextEditingController> _blockControllers = {};
  final Map<String, FocusNode> _blockFocusNodes = {};

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
            p.searchText.toLowerCase().contains(q);
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
    _titleController.addListener(_onTitleChanged);
    _searchController.addListener(_onSearchChanged);
    _loadPages();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _searchController.dispose();
    for (final c in _blockControllers.values) {
      c.dispose();
    }
    for (final n in _blockFocusNodes.values) {
      n.dispose();
    }
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
          updatedAt: DateTime.now(),
          isFavorite: true,
          blocks: [
            NoteBlock(
              id: '${DateTime.now().microsecondsSinceEpoch}-1',
              type: BlockType.heading,
              text: 'Notion-style Blocks',
            ),
            NoteBlock(
              id: '${DateTime.now().microsecondsSinceEpoch}-2',
              type: BlockType.paragraph,
              text: 'Type / in an empty block to open block commands.',
            ),
            NoteBlock(
              id: '${DateTime.now().microsecondsSinceEpoch}-3',
              type: BlockType.todo,
              text: 'Try drag-and-drop reorder',
            ),
          ],
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
    _isHydratingTitle = true;
    _titleController.text = page?.title ?? '';
    _isHydratingTitle = false;
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

  void _onTitleChanged() {
    if (_isHydratingTitle) {
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
      page.updatedAt = DateTime.now();
      _selectedPageId = page.id;
    });
    _savePages();
  }

  Future<void> _createPage() async {
    final page = NotePage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'Untitled',
      updatedAt: DateTime.now(),
      isFavorite: false,
      blocks: [
        NoteBlock(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          type: BlockType.paragraph,
          text: '',
        ),
      ],
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
      updatedAt: DateTime.now(),
      isFavorite: false,
      parentId: parent.id,
      blocks: [
        NoteBlock(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          type: BlockType.paragraph,
          text: '',
        ),
      ],
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
    for (final item in _pages.where((p) => removingIds.contains(p.id))) {
      _disposePageControllers(item);
    }

    setState(() {
      _pages.removeWhere((p) => removingIds.contains(p.id));
      _selectedPageId = _visiblePageNodes.firstOrNull?.page.id;
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  void _disposePageControllers(NotePage page) {
    for (final block in page.blocks) {
      _blockControllers.remove(block.id)?.dispose();
      _blockFocusNodes.remove(block.id)?.dispose();
    }
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

    for (final c in _blockControllers.values) {
      c.dispose();
    }
    _blockControllers.clear();
    for (final n in _blockFocusNodes.values) {
      n.dispose();
    }
    _blockFocusNodes.clear();

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

  TextEditingController _controllerForBlock(NoteBlock block) {
    final existing = _blockControllers[block.id];
    if (existing != null) {
      if (existing.text != block.text) {
        existing.value = TextEditingValue(
          text: block.text,
          selection: TextSelection.collapsed(offset: block.text.length),
        );
      }
      return existing;
    }

    final controller = TextEditingController(text: block.text);
    _blockControllers[block.id] = controller;
    return controller;
  }

  FocusNode _focusForBlock(NoteBlock block) {
    final existing = _blockFocusNodes[block.id];
    if (existing != null) {
      return existing;
    }
    final node = FocusNode();
    _blockFocusNodes[block.id] = node;
    return node;
  }

  Future<void> _updateBlockText(NoteBlock block, String text) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }

    setState(() {
      block.text = text;
      page.updatedAt = DateTime.now();
    });
    await _savePages();
  }

  Future<void> _toggleTodo(NoteBlock block, bool checked) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }

    setState(() {
      block.checked = checked;
      page.updatedAt = DateTime.now();
    });
    await _savePages();
  }

  Future<void> _addBlock({
    BlockType type = BlockType.paragraph,
    int? at,
  }) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }

    final newBlock = NoteBlock(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      text: '',
      checked: false,
    );

    setState(() {
      final index = at ?? page.blocks.length;
      page.blocks.insert(index.clamp(0, page.blocks.length), newBlock);
      page.updatedAt = DateTime.now();
    });
    await _savePages();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusForBlock(newBlock).requestFocus();
    });
  }

  Future<void> _deleteBlock(NoteBlock block) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }
    if (page.blocks.length == 1) {
      await _updateBlockText(block, '');
      return;
    }

    setState(() {
      page.blocks.removeWhere((b) => b.id == block.id);
      page.updatedAt = DateTime.now();
    });

    _blockControllers.remove(block.id)?.dispose();
    _blockFocusNodes.remove(block.id)?.dispose();
    await _savePages();
  }

  Future<void> _changeBlockType(NoteBlock block, BlockType type) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }

    setState(() {
      block.type = type;
      if (type != BlockType.todo) {
        block.checked = false;
      }
      if (type == BlockType.code && block.tone == BlockTone.normal) {
        block.tone = BlockTone.blue;
      }
      page.updatedAt = DateTime.now();
    });
    await _savePages();
  }

  Future<void> _changeBlockTone(NoteBlock block, BlockTone tone) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }
    setState(() {
      block.tone = tone;
      page.updatedAt = DateTime.now();
    });
    await _savePages();
  }

  Future<void> _reorderBlocks(int oldIndex, int newIndex) async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final block = page.blocks.removeAt(oldIndex);
      page.blocks.insert(newIndex, block);
      page.updatedAt = DateTime.now();
    });
    await _savePages();
  }

  Future<void> _handleSlash(NoteBlock block) async {
    final result = await showModalBottomSheet<BlockType>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.subject),
                title: const Text('Paragraph'),
                onTap: () => Navigator.pop(context, BlockType.paragraph),
              ),
              ListTile(
                leading: const Icon(Icons.title),
                title: const Text('Heading'),
                onTap: () => Navigator.pop(context, BlockType.heading),
              ),
              ListTile(
                leading: const Icon(Icons.check_box_outlined),
                title: const Text('Todo'),
                onTap: () => Navigator.pop(context, BlockType.todo),
              ),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('Code'),
                onTap: () => Navigator.pop(context, BlockType.code),
              ),
            ],
          ),
        );
      },
    );

    if (result != null) {
      await _changeBlockType(block, result);
    }
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
          PopupMenuButton<String>(
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
          ),
          IconButton(
            tooltip: _isMarkdownPreview ? 'Edit mode' : 'Markdown preview',
            onPressed: () {
              setState(() {
                _isMarkdownPreview = !_isMarkdownPreview;
              });
            },
            icon: Icon(
              _isMarkdownPreview
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
        ],
      ),
      body: _mobileTabIndex == 0
          ? _buildPagesPane(compact: true)
          : _buildEditorPane(selected, compact: true),
      floatingActionButton: _mobileTabIndex == 1
          ? FloatingActionButton.extended(
              onPressed: () => _addBlock(),
              icon: const Icon(Icons.add),
              label: const Text('Block'),
            )
          : null,
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
          PopupMenuButton<String>(
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
          ),
          IconButton(
            tooltip: _isMarkdownPreview ? 'Edit mode' : 'Markdown preview',
            onPressed: () {
              setState(() {
                _isMarkdownPreview = !_isMarkdownPreview;
              });
            },
            icon: Icon(
              _isMarkdownPreview
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addBlock(),
        icon: const Icon(Icons.add),
        label: const Text('New Block'),
      ),
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
          Text(
            'Type / in an empty block for commands',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isMarkdownPreview
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Markdown(
                      data: _pageToMarkdown(selected),
                      selectable: true,
                    ),
                  )
                : ReorderableListView.builder(
                    onReorder: _reorderBlocks,
                    itemCount: selected.blocks.length,
                    itemBuilder: (context, index) {
                      final block = selected.blocks[index];
                      return _BlockRow(
                        key: ValueKey(block.id),
                        block: block,
                        controller: _controllerForBlock(block),
                        focusNode: _focusForBlock(block),
                        textColor: _toneColor(context, block.tone),
                        onChanged: (value) async {
                          if (value == '/' && block.text.isEmpty) {
                            await _handleSlash(block);
                            return;
                          }
                          await _updateBlockText(block, value);
                        },
                        onToggleTodo: (value) => _toggleTodo(block, value),
                        onDelete: () => _deleteBlock(block),
                        onSlashCommand: () => _handleSlash(block),
                        onInsertBelow: () => _addBlock(at: index + 1),
                        onChangeType: (type) => _changeBlockType(block, type),
                        onChangeTone: (tone) => _changeBlockTone(block, tone),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _pageToMarkdown(NotePage page) {
    final lines = <String>[];
    for (final block in page.blocks) {
      final t = block.text;
      switch (block.type) {
        case BlockType.heading:
          lines.add('# $t');
          break;
        case BlockType.todo:
          lines.add('- [${block.checked ? 'x' : ' '}] $t');
          break;
        case BlockType.code:
          lines.add('```');
          lines.add(t);
          lines.add('```');
          break;
        case BlockType.paragraph:
          lines.add(t);
          break;
      }
      lines.add('');
    }
    return lines.join('\n').trim();
  }

  Color _toneColor(BuildContext context, BlockTone tone) {
    final scheme = Theme.of(context).colorScheme;
    return switch (tone) {
      BlockTone.red => Colors.red.shade700,
      BlockTone.orange => Colors.orange.shade800,
      BlockTone.green => Colors.green.shade700,
      BlockTone.blue => Colors.blue.shade700,
      BlockTone.purple => Colors.purple.shade700,
      BlockTone.normal => scheme.onSurface,
    };
  }

  Future<void> _exportCurrentPageMarkdown() async {
    final page = _selectedPage;
    if (page == null) {
      return;
    }
    final md = '# ${page.title}\n\n${_pageToMarkdown(page)}\n';
    await _shareExportContent(
      content: md,
      fileName: '${_safeFileName(page.title)}.md',
      mimeType: 'text/markdown',
      successMessage: 'Markdown exported',
      webFallbackMessage: 'Markdown copied to clipboard',
    );
  }

  Future<void> _exportAllPagesJson() async {
    final jsonData = const JsonEncoder.withIndent('  ').convert(
      _pages.map((p) => p.toJson()).toList(),
    );
    await _shareExportContent(
      content: jsonData,
      fileName: 'notion-lite-export-${DateTime.now().millisecondsSinceEpoch}.json',
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(webFallbackMessage)),
        );
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsString(content);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: mimeType)],
        text: 'Exported from Notion Lite Local',
      );

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage)),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  String _safeFileName(String raw) {
    final normalized = raw.trim().isEmpty ? 'untitled' : raw.trim();
    return normalized.replaceAll(RegExp(r'[\\\\/:*?"<>|\\s]+'), '-');
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

class _BlockRow extends StatelessWidget {
  const _BlockRow({
    super.key,
    required this.block,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onToggleTodo,
    required this.onDelete,
    required this.onSlashCommand,
    required this.onInsertBelow,
    required this.onChangeType,
    required this.onChangeTone,
    required this.textColor,
  });

  final NoteBlock block;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onToggleTodo;
  final VoidCallback onDelete;
  final VoidCallback onSlashCommand;
  final VoidCallback onInsertBelow;
  final ValueChanged<BlockType> onChangeType;
  final ValueChanged<BlockTone> onChangeTone;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final baseStyle = switch (block.type) {
      BlockType.heading => Theme.of(context).textTheme.headlineSmall,
      BlockType.code => Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
      _ => Theme.of(context).textTheme.bodyLarge,
    };
    final textStyle = (baseStyle ?? const TextStyle()).copyWith(
      color: textColor,
    );

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Row(
              children: [
                if (block.type == BlockType.todo)
                  Checkbox(
                    value: block.checked,
                    onChanged: (value) => onToggleTodo(value ?? false),
                  )
                else
                  IconButton(
                    tooltip: 'Slash command',
                    onPressed: onSlashCommand,
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              padding: block.type == BlockType.code
                  ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
                  : EdgeInsets.zero,
              decoration: block.type == BlockType.code
                  ? BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                style: textStyle,
                onChanged: onChanged,
                minLines: 1,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: _hint(block.type),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Block menu',
            onSelected: (value) {
              switch (value) {
                case 'type:paragraph':
                  onChangeType(BlockType.paragraph);
                  break;
                case 'type:heading':
                  onChangeType(BlockType.heading);
                  break;
                case 'type:todo':
                  onChangeType(BlockType.todo);
                  break;
                case 'type:code':
                  onChangeType(BlockType.code);
                  break;
                case 'tone:normal':
                  onChangeTone(BlockTone.normal);
                  break;
                case 'tone:red':
                  onChangeTone(BlockTone.red);
                  break;
                case 'tone:orange':
                  onChangeTone(BlockTone.orange);
                  break;
                case 'tone:green':
                  onChangeTone(BlockTone.green);
                  break;
                case 'tone:blue':
                  onChangeTone(BlockTone.blue);
                  break;
                case 'tone:purple':
                  onChangeTone(BlockTone.purple);
                  break;
                case 'insert':
                  onInsertBelow();
                  break;
                case 'delete':
                  onDelete();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'type:paragraph',
                child: Text('Type: Paragraph'),
              ),
              const PopupMenuItem(
                value: 'type:heading',
                child: Text('Type: Heading'),
              ),
              const PopupMenuItem(
                value: 'type:todo',
                child: Text('Type: Todo'),
              ),
              const PopupMenuItem(
                value: 'type:code',
                child: Text('Type: Code'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'tone:normal',
                child: Text('Color: Default'),
              ),
              const PopupMenuItem(value: 'tone:red', child: Text('Color: Red')),
              const PopupMenuItem(
                value: 'tone:orange',
                child: Text('Color: Orange'),
              ),
              const PopupMenuItem(
                value: 'tone:green',
                child: Text('Color: Green'),
              ),
              const PopupMenuItem(
                value: 'tone:blue',
                child: Text('Color: Blue'),
              ),
              const PopupMenuItem(
                value: 'tone:purple',
                child: Text('Color: Purple'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'insert', child: Text('Insert below')),
              const PopupMenuItem(value: 'delete', child: Text('Delete block')),
            ],
            icon: const Icon(Icons.drag_indicator),
          ),
        ],
      ),
    );
  }

  static String _hint(BlockType type) {
    return switch (type) {
      BlockType.heading => 'Heading',
      BlockType.todo => 'Todo item',
      BlockType.code => 'Code block',
      BlockType.paragraph => 'Type "/" for commands',
    };
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
