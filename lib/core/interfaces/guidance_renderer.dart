import '../models/guidance_event.dart';
import '../models/guidance_mode.dart';

abstract class GuidanceRenderer {
  Future<void> render({
    required GuidanceMode mode,
    required List<GuidanceEvent> events,
  });
}
