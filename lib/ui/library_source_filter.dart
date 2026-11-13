import 'package:flutter/material.dart';
import '../l10n/strings.dart';

const librarySourceKinds = {'local', 'webdav', 'smb'};

/// Source unions are evaluated once per catalog/filter change, never per tile.
List<Map<String, Object?>> filterLibraryWorks({
  required List<Map<String, Object?>> works,
  required List<Map<String, Object?>> assets,
  required List<Map<String, Object?>> sources,
  required Set<String> kinds,
  required String query,
  bool pendingReviewOnly = false,
}) {
  final all = kinds.containsAll(librarySourceKinds);
  final search = query.trim().toLowerCase();
  bool matchesWork(Map<String, Object?> w) {
    if (pendingReviewOnly && w['needs_review'] != 1) return false;
    return w['title'].toString().toLowerCase().contains(search);
  }

  if (all) {
    return works.where(matchesWork).toList();
  }
  final sourceIds = sources
      .where((s) => kinds.contains(s['kind']))
      .map((s) => s['id'])
      .toSet();
  final workIds = assets
      .where((a) => sourceIds.contains(a['source_id']))
      .map((a) => a['work_id'])
      .toSet();
  return works
      .where((w) => workIds.contains(w['id']) && matchesWork(w))
      .toList();
}

class LibrarySourceFilter extends StatelessWidget {
  const LibrarySourceFilter({
    super.key,
    required this.kinds,
    required this.count,
    required this.onChanged,
    this.pendingReviewOnly = false,
    this.pendingReviewCount = 0,
    this.onPendingReviewChanged,
  });
  final Set<String> kinds;
  final int count;
  final ValueChanged<Set<String>> onChanged;
  final bool pendingReviewOnly;
  final int pendingReviewCount;
  final ValueChanged<bool>? onPendingReviewChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labels = {
      'local': context.l10n.localMedia,
      'webdav': 'WebDAV',
      'smb': 'SMB',
    };
    final all = kinds.containsAll(librarySourceKinds);
    final baseTitle = all
        ? context.l10n.allWorks
        : kinds.length == 1
        ? labels[kinds.single]!
        : context.l10n.sources;
    final title = pendingReviewOnly
        ? '$baseTitle · ${context.l10n.pendingReviewOnly}'
        : baseTitle;
    Widget option(
      String key,
      String label,
      bool checked,
      VoidCallback toggle, {
      bool mixed = false,
    }) => MenuItemButton(
      key: ValueKey(key),
      closeOnActivate: false,
      onPressed: toggle,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(208, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? colors.onSurface.withValues(alpha: .06)
              : Colors.transparent,
        ),
        textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      trailingIcon: Icon(
        mixed ? Icons.remove : Icons.check,
        size: 17,
        color: checked || mixed ? colors.onSurface : Colors.transparent,
      ),
      child: Semantics(checked: checked, child: Text(label)),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: MenuAnchor(
            alignmentOffset: const Offset(0, 8),
            style: MenuStyle(
              backgroundColor: WidgetStatePropertyAll(colors.surface),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              elevation: const WidgetStatePropertyAll(2),
              shadowColor: WidgetStatePropertyAll(
                Colors.black.withValues(alpha: .08),
              ),
              padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
              side: WidgetStatePropertyAll(
                BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            menuChildren: [
              option(
                'source-filter-all',
                context.l10n.allWorks,
                all,
                () => onChanged(all ? {} : {...librarySourceKinds}),
                mixed: !all && kinds.isNotEmpty,
              ),
              const Divider(height: 1),
              for (final kind in librarySourceKinds)
                option(
                  'source-filter-$kind',
                  labels[kind]!,
                  kinds.contains(kind),
                  () => onChanged(
                    kinds.contains(kind)
                        ? ({...kinds}..remove(kind))
                        : {...kinds, kind},
                  ),
                ),
              if (onPendingReviewChanged != null &&
                  (pendingReviewCount > 0 || pendingReviewOnly)) ...[
                const Divider(height: 1),
                option(
                  'source-filter-pending-review',
                  '${context.l10n.pendingReviewOnly} ($pendingReviewCount)',
                  pendingReviewOnly,
                  () => onPendingReviewChanged!(!pendingReviewOnly),
                ),
              ],
            ],
            builder: (context, controller, child) => TextButton(
              key: const ValueKey('library-source-filter'),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Container(
          key: const ValueKey('library-work-count'),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            context.l10n.compactWorkCount(count),
            style: TextStyle(
              color: colors.primary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
