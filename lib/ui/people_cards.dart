import 'package:flutter/material.dart';
import 'horizontal_rail.dart';

class PeopleCards extends StatelessWidget {
  const PeopleCards({
    super.key,
    required this.cards,
    this.imageBuilder,
    this.showVoiceActors = false,
  });
  final List<Map<String, dynamic>> cards;
  final Widget Function(String? url)? imageBuilder;
  final bool showVoiceActors;

  ({String title, String subtitle}) _labels(Map<String, dynamic> card) {
    final title = card['title'] as String;
    final subtitle = card['subtitle'] as String;
    return showVoiceActors && subtitle.trim().isNotEmpty
        ? (title: subtitle, subtitle: title)
        : (title: title, subtitle: subtitle);
  }

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
              showVoiceActors: showVoiceActors,
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
          final labels = _labels(card);
          return SizedBox(
            width: 104,
            child: Column(
              children: [
                imageBuilder!(
                  card[showVoiceActors ? 'alternateImage' : 'image'] as String?,
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: labels.title,
                  child: Text(
                    labels.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 16, height: 1.5),
                  ),
                ),
                Tooltip(
                  message: labels.subtitle,
                  child: Text(
                    labels.subtitle,
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
        for (final labels in cards.map(_labels))
          ListTile(
            dense: true,
            title: Text(labels.title),
            subtitle: labels.subtitle.isEmpty ? null : Text(labels.subtitle),
          ),
      ],
    );
  }
}
