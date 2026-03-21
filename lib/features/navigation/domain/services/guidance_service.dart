import '../../../../core/models/navigation_command.dart';

class GuidanceService {
  const GuidanceService();

  List<NavigationCommand> filterCommands({
    required List<NavigationCommand> commands,
    required bool announceCurrentLocation,
  }) {
    if (announceCurrentLocation) return commands;
    return commands.where((command) => !command.isLocationAnnouncement).toList();
  }

  List<NavigationCommand> commandsForPlayback({
    required List<NavigationCommand> commands,
    required bool playFullCommands,
  }) {
    if (playFullCommands) return commands;
    if (commands.isEmpty) return const [];

    final result = <NavigationCommand>[];
    bool foundForward = false;
    int i = 0;

    for (; i < commands.length; i++) {
      result.add(commands[i]);
      if (commands[i].isForward) {
        foundForward = true;
        i++;
        break;
      }
    }

    if (!foundForward) return result;

    for (; i < commands.length; i++) {
      if (commands[i].isTurn || commands[i].isForward) break;
      result.add(commands[i]);
    }

    return result;
  }

  List<String> textsFromCommands(List<NavigationCommand> commands) {
    return commands.map((command) => command.text).where((text) => text.isNotEmpty).toList();
  }

  String buildSignature(List<NavigationCommand> commands) {
    return commands.map((command) => '${command.tag}::${command.text}').join('|');
  }

  String buildPlaybackModeAnnouncement({
    required String languageCode,
    required bool playFullCommands,
  }) {
    if (playFullCommands) {
      if (languageCode == 'zh') return '已切换为全程播报';
      if (languageCode == 'th') return 'สลับเป็นการบอกเส้นทางทั้งหมด';
      return 'Switched to full instructions';
    }

    if (languageCode == 'zh') return '已切换为分步播报';
    if (languageCode == 'th') return 'สลับเป็นการบอกทีละขั้น';
    return 'Switched to step-by-step instructions';
  }

  String buildErrorMessage({
    required String languageCode,
    String? backendError,
  }) {
    if (backendError != null && backendError.isNotEmpty) return backendError;
    if (languageCode == 'zh') return '网络或内部错误。';
    if (languageCode == 'th') return 'เกิดข้อผิดพลาดของระบบหรือเครือข่าย';
    return 'Network or internal error.';
  }
}
