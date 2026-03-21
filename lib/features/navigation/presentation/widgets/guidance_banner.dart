import 'package:flutter/material.dart';

import '../../../../core/models/tracking_state.dart';

class GuidanceBanner extends StatelessWidget {
  final TrackingState trackingState;
  final String? message;
  final double remainingDistancePx;
  final double distanceToNextWaypointPx;

  const GuidanceBanner({
    super.key,
    required this.trackingState,
    required this.message,
    required this.remainingDistancePx,
    required this.distanceToNextWaypointPx,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _colorForState(trackingState);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium!.copyWith(color: Colors.white),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _titleForState(trackingState),
              style: theme.textTheme.titleMedium!.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(message?.isNotEmpty == true ? message! : 'Waiting for navigation update.'),
            const SizedBox(height: 8),
            Text(
              'Remaining ${remainingDistancePx.toStringAsFixed(0)} px • Next waypoint ${distanceToNextWaypointPx.toStringAsFixed(0)} px',
              style: theme.textTheme.bodySmall!.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Color _colorForState(TrackingState state) {
    switch (state) {
      case TrackingState.offRoute:
        return const Color(0xFF8C2F39);
      case TrackingState.arrived:
        return const Color(0xFF1D6F5F);
      case TrackingState.localizing:
        return const Color(0xFF455A64);
      case TrackingState.replanning:
        return const Color(0xFF7A5C00);
      case TrackingState.idle:
      case TrackingState.tracking:
        return const Color(0xFF1F3C88);
    }
  }

  String _titleForState(TrackingState state) {
    switch (state) {
      case TrackingState.offRoute:
        return 'Off Route';
      case TrackingState.arrived:
        return 'Arrived';
      case TrackingState.localizing:
        return 'Localizing';
      case TrackingState.replanning:
        return 'Replanning';
      case TrackingState.idle:
        return 'Ready';
      case TrackingState.tracking:
        return 'Tracking';
    }
  }
}
