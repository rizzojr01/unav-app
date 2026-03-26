import '../api/api_service.dart';

enum RealtimeVoiceAgentAvailability {
  unsupported,
  tokenReady,
}

class RealtimeVoiceAgentSession {
  final String? clientSecret;
  final Map<String, dynamic> payload;

  const RealtimeVoiceAgentSession({
    required this.clientSecret,
    required this.payload,
  });
}

class RealtimeVoiceAgentService {
  RealtimeVoiceAgentAvailability get availability =>
      RealtimeVoiceAgentAvailability.tokenReady;

  Future<RealtimeVoiceAgentSession> createSession() async {
    final payload = await ApiService.createRealtimeSessionToken();
    final secret = _extractClientSecret(payload);
    return RealtimeVoiceAgentSession(
      clientSecret: secret,
      payload: payload,
    );
  }

  String? _extractClientSecret(Map<String, dynamic> payload) {
    final direct = payload['value'];
    if (direct is String && direct.isNotEmpty) {
      return direct;
    }

    final clientSecret = payload['client_secret'];
    if (clientSecret is Map<String, dynamic>) {
      final value = clientSecret['value'];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }
}
