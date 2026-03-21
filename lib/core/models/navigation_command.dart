class NavigationCommand {
  final String tag;
  final String text;

  const NavigationCommand({
    required this.tag,
    required this.text,
  });

  bool get isForward => tag == 'forward' || tag == 'forward_door';
  bool get isTurn => tag == 'turn' || tag == 'u_turn';
  bool get isLocationAnnouncement => tag == 'start_in';
}
