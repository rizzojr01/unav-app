import 'dart:ui';

import '../../../../core/models/localized_pose.dart';
import '../../../../core/models/navigation_command.dart';
import '../../../../core/models/navigation_route.dart';
import '../../../../core/utils/route_snap.dart';

class ParsedNavigationResult {
  final String mapKey;
  final NavigationRoute route;
  final LocalizedPose? pose;

  const ParsedNavigationResult({
    required this.mapKey,
    required this.route,
    required this.pose,
  });
}

class NavigationResultParser {
  const NavigationResultParser();

  ParsedNavigationResult parse(
    Map<String, dynamic> result, {
    bool snapToRoute = true,
  }) {
    final mapKey = ((result['best_map_key'] as List?) ?? const [])
        .take(3)
        .map((item) => item.toString())
        .join('|');

    final pathKeys = (result['result']?['path_keys'] as List?) ?? const [];
    final pathCoords = (result['result']?['path_coords'] as List?) ?? const [];
    final floorSegs = splitPathByFloor(pathKeys, pathCoords);
    final commands = parseCommands(result['cmds']);
    final routeNet = parseRouteNetworkSegments(result['route_segments']);

    var pose = parseFloorplanPose(result, mapKey);
    if (snapToRoute && pose != null && routeNet.isNotEmpty) {
      final snapped = snapToRouteNetwork(Offset(pose.x, pose.y), routeNet);
      pose = LocalizedPose(
        floorKey: pose.floorKey,
        x: snapped.dx,
        y: snapped.dy,
        heading: pose.heading,
        confidence: pose.confidence,
        timestamp: pose.timestamp,
      );
    }

    return ParsedNavigationResult(
      mapKey: mapKey,
      route: NavigationRoute(
        floorKey: mapKey,
        points: floorSegs[mapKey] ?? const [],
        commands: commands,
        routeNetworkSegments: routeNet,
      ),
      pose: pose,
    );
  }

  List<NavigationCommand> parseCommands(dynamic rawCmds) {
    final cmds = rawCmds is List ? rawCmds : const [];
    return cmds
        .whereType<Map<String, dynamic>>()
        .map((cmd) => NavigationCommand(
              tag: cmd['tag']?.toString() ?? '',
              text: cmd['text']?.toString() ?? '',
            ))
        .toList();
  }

  LocalizedPose? parseFloorplanPose(Map<String, dynamic> navResultData, String floorKey) {
    final dynamic pose = navResultData['floorplan_pose'];
    if (pose is! Map) return null;

    double? readNum(dynamic value) => value is num ? value.toDouble() : null;

    final double? x = readNum(pose['x']) ??
        readNum(pose['px']) ??
        readNum(pose['u']) ??
        readNum(pose['col']);
    final double? y = readNum(pose['y']) ??
        readNum(pose['py']) ??
        readNum(pose['v']) ??
        readNum(pose['row']);
    final double heading = readNum(pose['ang']) ?? readNum(pose['heading']) ?? 0;
    final double confidence = readNum(pose['confidence']) ?? 1;

    if (x != null && y != null) {
      return LocalizedPose(
        floorKey: floorKey,
        x: x,
        y: y,
        heading: heading,
        confidence: confidence,
        timestamp: DateTime.now(),
      );
    }

    final dynamic xy = pose['xy'] ?? pose['point'] ?? pose['position'] ?? pose['loc'];
    if (xy is List && xy.length >= 2 && xy[0] is num && xy[1] is num) {
      return LocalizedPose(
        floorKey: floorKey,
        x: (xy[0] as num).toDouble(),
        y: (xy[1] as num).toDouble(),
        heading: heading,
        confidence: confidence,
        timestamp: DateTime.now(),
      );
    }

    return null;
  }

  List<(Offset, Offset)> parseRouteNetworkSegments(dynamic raw) {
    if (raw is! List) return const [];
    final result = <(Offset, Offset)>[];
    for (final seg in raw) {
      if (seg is! Map) continue;
      final from = seg['from'];
      final to = seg['to'];
      if (from is! List || to is! List || from.length < 2 || to.length < 2) continue;
      result.add((
        Offset((from[0] as num).toDouble(), (from[1] as num).toDouble()),
        Offset((to[0] as num).toDouble(), (to[1] as num).toDouble()),
      ));
    }
    return result;
  }

  Map<String, List<Offset>> splitPathByFloor(
    List<dynamic> pathKeys,
    List<dynamic> pathCoords,
  ) {
    final Map<String, List<Offset>> floorSegs = {};
    Offset? startCoord;
    bool startInserted = false;

    for (int i = 0; i < pathKeys.length; ++i) {
      final dynamic key = pathKeys[i];
      final dynamic coord = pathCoords[i];

      if (coord is! List || coord.length < 2) continue;

      if (key == 'VIRT') {
        startCoord = Offset((coord[0] as num).toDouble(), (coord[1] as num).toDouble());
        continue;
      }

      if (key is List && key.length >= 3) {
        final floorKey = '${key[0]}|${key[1]}|${key[2]}';
        floorSegs.putIfAbsent(floorKey, () => []);
        if (startCoord != null && !startInserted) {
          floorSegs[floorKey]!.add(startCoord);
          startInserted = true;
        }
        floorSegs[floorKey]!.add(
          Offset((coord[0] as num).toDouble(), (coord[1] as num).toDouble()),
        );
      }
    }

    return floorSegs;
  }
}
