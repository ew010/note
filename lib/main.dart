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
      title: 'Notion Lite Local',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B3B3B)),
        useMaterial3: true,
      ),
      home: const NotesHomePage(),
    );
  }
}

enum BlockType { paragraph, heading, todo }

class NoteBlock {
  NoteBlock({
    required this.id,
    required this.type,
    required this.text,
    this.checked = false,
  });

  final String id;
  BlockType type;
  String text;
  bool checked;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'text': text,
    'checked': checked,
  };

  static NoteBlock fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'paragraph';
    final type = BlockType.values.firstWhere(
      (item) => item.name == typeStr,
      orElse: () => BlockType.paragraph,
    );
    return NoteBlock(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      text: json['text'] as String? ?? '',
      checked: json['checked'] as bool? ?? false,
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
  });

  final String id;
  String title;
  DateTime updatedAt;
  bool isFavorite;
  List<NoteBlock> blocks;

  String get searchText => blocks.map((b) => b.text).join('\n');

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt.toIso8601String(),
    'isFavorite': isFavorite,
    'blocks': blocks.map((b) => b.toJson()).toList(),
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

  final Map<String, TextEditingController> _blockControllers = {};
  final Map<String, FocusNode> _blockFocusNodes = {};

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
          p.searchText.toLowerCase().contains(q);
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
    _isHydratingTitle = true;
    _titleController.text = page?.title ?? '';
    _isHydratingTitle = false;
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

    if (!visible.any((p) => p.id == _selectedPageId)) {
      setState(() {
        _selectedPageId = visible.first.id;
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

  Future<void> _deleteSelectedPage() async {
    final page = _selectedPage;
    if (page == null || _pages.length == 1) {
      return;
    }

    _disposePageControllers(page);

    setState(() {
      _pages.removeWhere((p) => p.id == page.id);
      _selectedPageId = _visiblePages.firstOrNull?.id;
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
          IconButton(
            tooltip: 'New page',
            onPressed: _createPage,
            icon: const Icon(Icons.note_add_outlined),
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
                          color: page.isFavorite ? Colors.amber.shade700 : null,
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
            child: ReorderableListView.builder(
              onReorder: _reorderBlocks,
              itemCount: selected.blocks.length,
              itemBuilder: (context, index) {
                final block = selected.blocks[index];
                return _BlockRow(
                  key: ValueKey(block.id),
                  block: block,
                  controller: _controllerForBlock(block),
                  focusNode: _focusForBlock(block),
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
                );
              },
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
  });

  final NoteBlock block;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onToggleTodo;
  final VoidCallback onDelete;
  final VoidCallback onSlashCommand;
  final VoidCallback onInsertBelow;

  @override
  Widget build(BuildContext context) {
    final textStyle = switch (block.type) {
      BlockType.heading => Theme.of(context).textTheme.headlineSmall,
      _ => Theme.of(context).textTheme.bodyLarge,
    };

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
          PopupMenuButton<String>(
            tooltip: 'Block menu',
            onSelected: (value) {
              switch (value) {
                case 'paragraph':
                  onChanged(controller.text);
                  onSlashCommand();
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
      BlockType.paragraph => 'Type "/" for commands',
    };
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
