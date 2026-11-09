import 'package:flutter/material.dart';
import 'horizontal_rail.dart';

class PeopleCards extends StatelessWidget {
  const PeopleCards({
    super.key,
    required this.cards,
    this.imageBuilder,
    this.alternateImages = false,
  });
  final List<Map<String, dynamic>> cards;
  final Widget Function(String? url)? imageBuilder;
  final bool alternateImages;

  @override
  Widget build(BuildContext context) {
    if (cards.any((card) => card['section'] != null)) {
      final sections = <String, List<Map<String, dynamic>>>{};
      for (final card in cards) {
        final section = card['section'] as String? ?? '';
        (sections[section] ??= []).add({...card}..remove('section'));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in sections.entries) ...[
            if (section.key.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  section.key,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            PeopleCards(
              cards: section.value,
              imageBuilder: imageBuilder,
              alternateImages: alternateImages,
            ),
          ],
        ],
      );
    }
    if (imageBuilder != null) {
      return HorizontalRail(
        height:
            88 +
            MediaQuery.textScalerOf(context).scale(16) * 1.5 +
            MediaQuery.textScalerOf(context).scale(12) * 1.5,
        itemWidth: 104,
        spacing: 10,
        itemCount: cards.length,
        itemBuilder: (context, index) {
          final card = cards[index];
          final subtitle = alternateImages
              ? card['alternateSubtitle'] ?? card['subtitle']
              : card['subtitle'];
          return SizedBox(
            width: 104,
            child: Column(
              children: [
                imageBuilder!(
                  card[alternateImages ? 'alternateImage' : 'image'] as String?,
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: card['title'] as String,
                  child: Text(
                    card['title'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 16, height: 1.5),
                  ),
                ),
                Tooltip(
                  message: subtitle as String,
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final card in cards)
          ListTile(
            dense: true,
            title: Text(card['title'] as String),
            subtitle: (card['subtitle'] as String).isEmpty
                ? null
                : Text(card['subtitle'] as String),
          ),
      ],
    );
  }
}
