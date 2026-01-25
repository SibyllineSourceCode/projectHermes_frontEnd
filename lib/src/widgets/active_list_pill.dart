import 'package:flutter/material.dart';

class ActiveListPill extends StatelessWidget {
  const ActiveListPill({
    super.key,
    required this.title,
    required this.onTap,
    this.onLongPress,
  });

  final String title; // e.g. 'Security Logs' or 'None'
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNone = title.trim().isEmpty || title == 'None';

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(999),
      color: cs.surface.withOpacity(0.92),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.playlist_add_check_circle,
                size: 18,
                color: isNone ? cs.onSurface.withOpacity(0.5) : cs.primary,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  isNone ? 'No active list' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: isNone ? cs.onSurface.withOpacity(0.7) : cs.onSurface,
                      ),
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, size: 18, color: cs.onSurface.withOpacity(0.6)),
            ],
          ),
        ),
      ),
    );
  }
}
