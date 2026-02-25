import 'dart:convert';

import 'package:flutter/material.dart';
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
  });

  final String id;
  String title;
  String content;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static NotePage fromJson(Map<String, dynamic> json) {
    return NotePage(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled',
      content: json['content'] as String? ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class NotesHomePage extends StatefulWidget {
  const NotesHomePage({super.key});

  @override
  State<NotesHomePage> createState() => _NotesHomePageState();
}

class _NotesHomePageState extends State<NotesHomePage> {
  static const _storageKey = 'notion_lite_pages_v1';

  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  final List<NotePage> _pages = [];

  int _selectedIndex = 0;
  bool _isLoading = true;
  bool _isHydratingEditor = false;

  NotePage? get _selectedPage =>
      _pages.isEmpty || _selectedIndex >= _pages.length
      ? null
      : _pages[_selectedIndex];

  @override
  void initState() {
    super.initState();
    _titleController.addListener(_onEditorChanged);
    _contentController.addListener(_onEditorChanged);
    _loadPages();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
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
          content: '# Notion Lite\n\nStart writing here.',
          updatedAt: DateTime.now(),
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
      _pages.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isLoading = false;
      _selectedIndex = 0;
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
      _pages.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _selectedIndex = _pages.indexWhere((p) => p.id == page.id);
    });

    _savePages();
  }

  Future<void> _createPage() async {
    final page = NotePage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'Untitled',
      content: '',
      updatedAt: DateTime.now(),
    );

    setState(() {
      _pages.insert(0, page);
      _selectedIndex = 0;
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  Future<void> _deleteSelectedPage() async {
    if (_selectedPage == null || _pages.length == 1) {
      return;
    }

    final removingId = _selectedPage!.id;
    setState(() {
      _pages.removeWhere((p) => p.id == removingId);
      if (_selectedIndex >= _pages.length) {
        _selectedIndex = _pages.length - 1;
      }
    });

    _syncEditorFromSelected();
    await _savePages();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notion Lite'),
        actions: [
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
            width: 280,
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
                  child: Row(
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
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: _pages.length,
                    itemBuilder: (context, index) {
                      final page = _pages[index];
                      final selected = index == _selectedIndex;
                      return ListTile(
                        selected: selected,
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
                            _selectedIndex = index;
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
            child: _selectedPage == null
                ? const Center(child: Text('No page selected'))
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
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
                        const SizedBox(height: 8),
                        Expanded(
                          child: TextField(
                            controller: _contentController,
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            decoration: const InputDecoration(
                              hintText: 'Type / for commands (coming soon)',
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
