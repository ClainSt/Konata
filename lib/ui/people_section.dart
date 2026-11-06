import 'package:flutter/material.dart';
import 'managed_image.dart';

/// Uses the detail page's compact horizontal person cards for live-action data.
class PeopleSection extends StatelessWidget {
  const PeopleSection({super.key, required this.title, required this.people});
  final String title;
  final List<Map<String, dynamic>> people;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              color: scheme.onSurface.withValues(alpha: .7),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 100 + 58 * scale,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final person = people[index];
                final roles = (person['roles'] as List? ?? []).join(' / ');
                return SizedBox(
                  width: 112,
                  child: Column(
                    children: [
                      SizedBox(
                        width: 80,
                        height: 80,
                        child: ClipOval(
                          child: person['image'] == null
                              ? const ColoredBox(
                                  color: Color(0x11808080),
                                  child: Icon(Icons.person_outline),
                                )
                              : ManagedImage(
                                  person['image'].toString(),
                                  fit: BoxFit.cover,
                                ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        person['name']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (roles.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          roles,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurface.withValues(alpha: .55),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
