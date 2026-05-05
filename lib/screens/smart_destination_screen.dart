import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../api/api_service.dart';
import '../providers/settings_provider.dart';
import '../services/realtime_voice_agent_service.dart';
import '../services/tts_service.dart';
import 'navigation_screen.dart';
import 'startup_screen.dart';

class SmartDestinationScreen extends StatefulWidget {
  const SmartDestinationScreen({super.key});

  @override
  State<SmartDestinationScreen> createState() => _SmartDestinationScreenState();
}

class _SmartDestinationScreenState extends State<SmartDestinationScreen>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final RealtimeVoiceAgentService _realtimeVoiceAgentService =
      RealtimeVoiceAgentService();

  late final AnimationController _orbController;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _maxListenTimer;
  Timer? _silenceTimer;
  Timer? _autoListenTimer;

  bool _isListening = false;
  bool _isResolving = false;
  bool _isSpeakingResponse = false;
  bool _speechInterruptedByUser = false;
  bool _hasHeardVoice = false;
  String _statusText = 'Tap the button and tell me where you want to go.';
  String _lastHeardText = '';
  String _lastSubmittedUtterance = '';
  DateTime? _lastSubmittedAt;
  String? _backendStatus;
  String? _responseLanguage;
  List<Map<String, dynamic>> _candidateOptions = const [];
  Map<String, dynamic>? _lastDestinationQuery;
  Map<String, dynamic>? _conversationAnchorCandidate;
  bool _sessionContextPrimed = false;

  @override
  void initState() {
    super.initState();
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _warmRealtimeBridge();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _speakIntroPrompt();
    });
  }

  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    _maxListenTimer?.cancel();
    _silenceTimer?.cancel();
    _autoListenTimer?.cancel();
    _orbController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _warmRealtimeBridge() async {
    try {
      final session = await _realtimeVoiceAgentService.createSession();
      await _resetSmartSessionContext();
      if (!mounted) return;
      setState(() {
        _sessionContextPrimed = true;
        _backendStatus = session.clientSecret == null
            ? 'Cloud voice connected, but realtime setup is incomplete.'
            : null;
      });
    } catch (e) {
      try {
        await _resetSmartSessionContext();
        _sessionContextPrimed = true;
      } catch (_) {
        // Leave the screen usable even if the reset endpoint is temporarily unavailable.
      }
      if (!mounted) return;
      setState(() {
        _backendStatus = 'Cloud voice backend is not ready yet.';
      });
    }
  }

  Future<void> _resetSmartSessionContext() async {
    await ApiService.agentResetSessionContext();
    _candidateOptions = const [];
    _lastDestinationQuery = null;
    _responseLanguage = null;
    _conversationAnchorCandidate = null;
  }

  Future<void> _handleLogout() async {
    await ApiService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const StartupScreen()),
      (route) => false,
    );
  }

  Future<void> _toggleVoiceCapture() async {
    if (_isListening) {
      await _finishListening();
    } else if (_isSpeakingResponse) {
      await _interruptSpeechAndListen();
    } else if (_isResolving) {
      return;
    } else {
      await _startListening();
    }
  }

  Future<void> _interruptSpeechAndListen() async {
    _speechInterruptedByUser = true;
    _autoListenTimer?.cancel();
    await TTSService.stop();
    if (!mounted) return;
    setState(() {
      _isSpeakingResponse = false;
      _statusText = 'Listening...';
    });
    await _startListening();
  }

  Future<void> _speakIntroPrompt() async {
    final language = context.read<SettingsProvider>().languageCode;
    final intro = language == 'zh'
        ? '你想去哪里？请按下方按钮说话。'
        : language == 'th'
            ? 'คุณอยากไปที่ไหน กดปุ่มด้านล่างแล้วพูดได้เลย'
            : 'Where would you like to go? Press the button below to speak.';
    await TTSService.setLanguage(language);
    await TTSService.speakAndWait(intro);
    if (!mounted) return;
    setState(() {
      _statusText = intro;
    });
    _scheduleAutoListening();
  }

  void _scheduleAutoListening([Duration delay = const Duration(milliseconds: 500)]) {
    _autoListenTimer?.cancel();
    _autoListenTimer = Timer(delay, () {
      if (!mounted || _isListening || _isResolving) return;
      _startListening();
    });
  }

  Future<void> _startListening() async {
    final micPermission = await Permission.microphone.request();
    if (!mounted) return;
    if (!micPermission.isGranted) {
      _updateStatus('Microphone permission is required for Smart Mode voice input.');
      return;
    }

    final canRecord = await _audioRecorder.hasPermission();
    if (!canRecord) {
      _updateStatus('Audio recording is unavailable on this device right now.');
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final filePath =
        '${tempDir.path}/smart_mode_${DateTime.now().millisecondsSinceEpoch}.m4a';

    setState(() {
      _isListening = true;
      _statusText = 'Listening...';
      _lastHeardText = '';
      _hasHeardVoice = false;
    });
    await HapticFeedback.mediumImpact();

    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: filePath,
    );
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 180))
        .listen(_handleAmplitudeUpdate);
    _maxListenTimer?.cancel();
    _maxListenTimer = Timer(const Duration(seconds: 8), () {
      if (_isListening) {
        _finishListening();
      }
    });
  }

  Future<void> _finishListening() async {
    if (!_isListening) return;
    _maxListenTimer?.cancel();
    _silenceTimer?.cancel();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    setState(() {
      _isListening = false;
      _statusText = 'Transcribing...';
    });
    await HapticFeedback.selectionClick();
    final audioPath = await _audioRecorder.stop();
    if (!mounted) return;
    if (audioPath == null || audioPath.isEmpty) {
      _updateStatus('I did not capture any audio. Please try again.');
      _scheduleAutoListening();
      return;
    }

    final language = context.read<SettingsProvider>().languageCode;
    final transcription = await ApiService.transcribeSmartModeAudio(
      filePath: audioPath,
      language: language,
      prompt:
          'The user is speaking to an indoor navigation assistant. Capture destination requests naturally, in any language.',
    );
    if (!mounted) return;

    if (transcription.containsKey('error')) {
      _updateStatus(transcription['error'].toString());
      _scheduleAutoListening();
      return;
    }

    final utterance = (transcription['text'] ?? '').toString().trim();
    if (utterance.isEmpty) {
      _updateStatus('I did not catch that. Please try saying your destination again.');
      _scheduleAutoListening();
      return;
    }
    if (_isRecentDuplicateUtterance(utterance)) {
      return;
    }

    setState(() {
      _lastHeardText = utterance;
      _statusText = utterance;
    });
    await _submitUtterance(utterance);
  }

  void _handleAmplitudeUpdate(Amplitude amplitude) {
    if (!_isListening) return;
    const speechThreshold = -34.0;
    const silenceThreshold = -42.0;

    if (amplitude.current > speechThreshold) {
      _hasHeardVoice = true;
      _silenceTimer?.cancel();
      return;
    }

    if (!_hasHeardVoice || amplitude.current > silenceThreshold) {
      return;
    }

    _silenceTimer ??= Timer(const Duration(milliseconds: 1100), () {
      _silenceTimer = null;
      if (_isListening) {
        _finishListening();
      }
    });
  }

  bool _isRecentDuplicateUtterance(String utterance) {
    final now = DateTime.now();
    if (_lastSubmittedUtterance != utterance) {
      return false;
    }
    if (_lastSubmittedAt == null) {
      return false;
    }
    return now.difference(_lastSubmittedAt!) < const Duration(seconds: 2);
  }

  Future<void> _submitUtterance(String utterance) async {
    if (_isResolving || _isRecentDuplicateUtterance(utterance)) return;
    final language = context.read<SettingsProvider>().languageCode;
    final priorSingleCandidate = _candidateOptions.length == 1
        ? Map<String, dynamic>.from(_candidateOptions.first)
        : null;
    if (_candidateOptions.isNotEmpty &&
        !_looksLikeFreshDestinationIntent(utterance) &&
        await _handleCandidateFollowUp(utterance)) {
      return;
    }

    if (!_sessionContextPrimed) {
      try {
        await _resetSmartSessionContext();
        _sessionContextPrimed = true;
      } catch (_) {
        // Continue; the backend may still handle this utterance correctly.
      }
    } else {
      try {
        await ApiService.agentResetSessionContext();
      } catch (_) {
        // Continue if reset fails transiently.
      }
      _candidateOptions = const [];
      _lastDestinationQuery = null;
    }

    if (priorSingleCandidate != null) {
      _conversationAnchorCandidate = priorSingleCandidate;
    }

    _lastSubmittedUtterance = utterance;
    _lastSubmittedAt = DateTime.now();
    setState(() {
      _isResolving = true;
      _candidateOptions = const [];
      _statusText = 'Understanding your destination...';
    });

    try {
      final interpretation = await ApiService.agentInterpretDestination(
        utterance: utterance,
        language: language,
      );
      if (!mounted) return;

      if (interpretation.containsKey('error')) {
        _updateStatus(interpretation['error'].toString());
        return;
      }

      final responseLanguage =
          (interpretation['response_language'] ?? language).toString();
      _responseLanguage = responseLanguage;

      final interpretationMessage = interpretation['message']?.toString();
      if (interpretationMessage != null && interpretationMessage.isNotEmpty) {
        await _speakAndShow(interpretationMessage, responseLanguage);
      }

      final destinationQuery =
          Map<String, dynamic>.from(interpretation['destination_query'] ?? const {});
      if (destinationQuery.isEmpty) {
        await _speakAndShow(
          _localizedFallback('I could not understand a destination from that request.', responseLanguage),
          responseLanguage,
        );
        return;
      }

      final contextualQuery = _applyConversationContext(destinationQuery);
      _lastDestinationQuery = contextualQuery;

      final resolution = await _resolveDestinationWithConversationContext(
        contextualQuery,
        responseLanguage: responseLanguage,
      );
      if (!mounted) return;

      if (resolution.containsKey('error')) {
        _updateStatus(resolution['error'].toString());
        return;
      }

      final resolvedLanguage =
          (resolution['response_language'] ?? responseLanguage).toString();
      _responseLanguage = resolvedLanguage;
      final message = resolution['message']?.toString();
      final candidates =
          List<Map<String, dynamic>>.from(resolution['candidates'] ?? const []);

      setState(() {
        _candidateOptions = candidates;
        if (candidates.length == 1) {
          _conversationAnchorCandidate = Map<String, dynamic>.from(candidates.first);
        }
        if (message != null && message.isNotEmpty) {
          _statusText = message;
        } else if (candidates.isNotEmpty) {
          _statusText = _localizedFallback(
            'I found some likely destinations. Choose one below.',
            resolvedLanguage,
          );
        }
      });

      if (message != null && message.isNotEmpty) {
        await _speakAndShow(message, resolvedLanguage, speakOnly: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResolving = false;
        });
      }
    }
  }

  Future<bool> _handleCandidateFollowUp(String utterance) async {
    final responseLanguage =
        _responseLanguage ?? context.read<SettingsProvider>().languageCode;
    final candidates = _candidateOptions;
    if (candidates.isEmpty) return false;

    if (await _resolveSameIntentAcrossRequestedFloor(utterance, responseLanguage)) {
      return true;
    }

    if (_looksLikeBroadenFloorRequest(utterance) &&
        await _resolveAcrossBroaderFloorScope(responseLanguage)) {
      return true;
    }

    if (_isAffirmative(utterance) && candidates.length == 1) {
      await _startNavigationFromCandidate(candidates.first);
      return true;
    }

    try {
      final followUp = await ApiService.agentFollowUpDestination(
        utterance: utterance,
        candidates: candidates,
        responseLanguage: responseLanguage,
      );

      if (!mounted) return true;

      if (!followUp.containsKey('error')) {
        final resolvedLanguage =
            (followUp['response_language'] ?? responseLanguage).toString();
        _responseLanguage = resolvedLanguage;
        final selectedIds = List<String>.from(
          (followUp['selected_destination_ids'] ?? const [])
              .map((id) => id.toString()),
        );
        final narrowed = _resolveSelectedCandidates(
          candidates: candidates,
          selectedIds: selectedIds,
          utterance: utterance,
        );
        final status = (followUp['status'] ?? '').toString();
        final message = followUp['message']?.toString();

        if (status == 'confirm' && narrowed.length == 1) {
          _conversationAnchorCandidate = Map<String, dynamic>.from(narrowed.first);
          await _startNavigationFromCandidate(narrowed.first);
          return true;
        }

        if (narrowed.isNotEmpty) {
          if (narrowed.length == 1) {
            setState(() {
              _candidateOptions = narrowed;
            });
            _conversationAnchorCandidate = Map<String, dynamic>.from(narrowed.first);
            await _speakAndShow(
              message?.isNotEmpty == true
                  ? message!
                  : _buildSingleCandidatePrompt(narrowed.first, resolvedLanguage),
              resolvedLanguage,
            );
            return true;
          }

          setState(() {
            _candidateOptions = narrowed;
          });
          await _speakAndShow(
            message?.isNotEmpty == true
                ? message!
                : _buildGroupedCandidatePrompt(narrowed, resolvedLanguage),
            resolvedLanguage,
          );
          return true;
        }

        if (status == 'unclear' || status == 'restart') {
          if (message != null && message.isNotEmpty) {
            await _speakAndShow(message, resolvedLanguage);
            return true;
          }
          if (status == 'unclear') {
            await _speakAndShow(
              _buildNoMatchSelectionPrompt(resolvedLanguage),
              resolvedLanguage,
            );
            return true;
          }
          return false;
        }
      }
    } catch (_) {
      // Fall back to local heuristics below if the backend follow-up agent is unavailable.
    }

    final narrowed = _narrowCandidates(candidates, utterance);
    if (narrowed.isEmpty) {
      if (_looksLikeSelectionUtterance(utterance)) {
        await _speakAndShow(
          _buildNoMatchSelectionPrompt(responseLanguage),
          responseLanguage,
        );
        return true;
      }
      return false;
    }

    if (narrowed.length == 1) {
      setState(() {
        _candidateOptions = narrowed;
      });
      if (_isAffirmative(utterance)) {
        await _startNavigationFromCandidate(narrowed.first);
        return true;
      }
      await _speakAndShow(
        _buildSingleCandidatePrompt(narrowed.first, responseLanguage),
        responseLanguage,
      );
      return true;
    }

    setState(() {
      _candidateOptions = narrowed;
    });
    await _speakAndShow(
      _buildGroupedCandidatePrompt(narrowed, responseLanguage),
      responseLanguage,
    );
    return true;
  }

  Future<bool> _resolveAcrossBroaderFloorScope(String responseLanguage) async {
    final previousQuery = _lastDestinationQuery;
    if (previousQuery == null || previousQuery.isEmpty) {
      return false;
    }

    final broadened = Map<String, dynamic>.from(previousQuery)
      ..remove('floor_hint')
      ..['search_scope'] = 'building';

    final firstCandidate = _candidateOptions.isNotEmpty ? _candidateOptions.first : null;
    if ((broadened['building_hint'] == null || broadened['building_hint'].toString().isEmpty) &&
        firstCandidate != null) {
      broadened['building_hint'] = firstCandidate['building'];
    }

    final resolution = await ApiService.agentResolveDestination(
      broadened,
      responseLanguage: responseLanguage,
    );
    if (!mounted) return true;
    if (resolution.containsKey('error')) {
      return false;
    }

    final resolvedLanguage =
        (resolution['response_language'] ?? responseLanguage).toString();
    _responseLanguage = resolvedLanguage;
    _lastDestinationQuery = broadened;
    final message = resolution['message']?.toString();
    final candidates =
        List<Map<String, dynamic>>.from(resolution['candidates'] ?? const []);

    if (candidates.isEmpty) {
      await _speakAndShow(
        message?.isNotEmpty == true
            ? message!
            : _localizedFallback(
                'I could not find more options on other floors.',
                resolvedLanguage,
              ),
        resolvedLanguage,
      );
      return true;
    }

    setState(() {
      _candidateOptions = candidates;
      if (candidates.length == 1) {
        _conversationAnchorCandidate = Map<String, dynamic>.from(candidates.first);
      }
    });

    await _speakAndShow(
      message?.isNotEmpty == true
          ? message!
          : _buildGroupedCandidatePrompt(candidates, resolvedLanguage),
      resolvedLanguage,
    );
    return true;
  }

  Future<bool> _resolveSameIntentAcrossRequestedFloor(
    String utterance,
    String responseLanguage,
  ) async {
    final previousQuery = _lastDestinationQuery;
    if (previousQuery == null || previousQuery.isEmpty) {
      return false;
    }

    final floorHints = _extractFloorHints(utterance).toSet();
    if (floorHints.isEmpty) {
      return false;
    }

    final sameCategory = _candidateOptions.isNotEmpty &&
        _candidateOptions
            .map((candidate) => (candidate['category'] ?? '').toString())
            .toSet()
            .length == 1;
    if (!sameCategory) {
      return false;
    }

    final requestedFloor = floorHints.firstWhere(
      (hint) => hint.endsWith('_floor'),
      orElse: () => floorHints.first,
    );
    final currentFloors = _candidateOptions
        .map((candidate) => (candidate['floor'] ?? '').toString().toLowerCase())
        .where((floor) => floor.isNotEmpty)
        .toSet();
    if (currentFloors.contains(requestedFloor.toLowerCase())) {
      return false;
    }

    final refined = Map<String, dynamic>.from(previousQuery)
      ..['floor_hint'] = requestedFloor
      ..['search_scope'] = 'building';

    final firstCandidate = _candidateOptions.first;
    if ((refined['building_hint'] == null || refined['building_hint'].toString().isEmpty) &&
        firstCandidate['building'] != null) {
      refined['building_hint'] = firstCandidate['building'];
    }

    final resolution = await _resolveDestinationWithConversationContext(
      refined,
      responseLanguage: responseLanguage,
    );
    if (!mounted) return true;
    if (resolution.containsKey('error')) {
      return false;
    }

    final resolvedLanguage =
        (resolution['response_language'] ?? responseLanguage).toString();
    _responseLanguage = resolvedLanguage;
    _lastDestinationQuery = refined;
    final message = resolution['message']?.toString();
    final candidates =
        List<Map<String, dynamic>>.from(resolution['candidates'] ?? const []);

    if (candidates.isEmpty) {
      return false;
    }

    setState(() {
      _candidateOptions = candidates;
      if (candidates.length == 1) {
        _conversationAnchorCandidate = Map<String, dynamic>.from(candidates.first);
      }
    });

    await _speakAndShow(
      message?.isNotEmpty == true
          ? message!
          : _buildGroupedCandidatePrompt(candidates, resolvedLanguage),
      resolvedLanguage,
    );
    return true;
  }

  Future<void> _speakAndShow(
    String text,
    String responseLanguage, {
    bool speakOnly = false,
  }) async {
    if (!speakOnly) {
      setState(() {
        _statusText = text;
        _isResolving = false;
        _isSpeakingResponse = true;
      });
    } else if (mounted) {
      setState(() {
        _isResolving = false;
        _isSpeakingResponse = true;
      });
    }
    _speechInterruptedByUser = false;
    try {
      await TTSService.setLanguage(_normalizeLanguageCode(responseLanguage, text));
      await TTSService.speakAndWait(text);
    } finally {
      if (mounted) {
        setState(() {
          _isSpeakingResponse = false;
        });
      }
    }
    if (!_speechInterruptedByUser) {
      _scheduleAutoListening();
    }
  }

  String _normalizeLanguageCode(String raw, String text) {
    final value = raw.toLowerCase();
    if (value.startsWith('zh')) return 'zh';
    if (value.startsWith('th')) return 'th';
    if (value.startsWith('es')) return 'es';
    if (value.startsWith('fr')) return 'fr';
    if (value.startsWith('de')) return 'de';
    if (value.startsWith('ja')) return 'ja';
    if (value.startsWith('ko')) return 'ko';
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) return 'zh';
    if (RegExp(r'[\u0E00-\u0E7F]').hasMatch(text)) return 'th';
    return 'en';
  }

  String _localizedFallback(String english, String language) {
    final normalized = _normalizeLanguageCode(language, '');
    if (normalized == 'zh') {
      switch (english) {
        case 'I could not understand a destination from that request.':
          return '我还没有听明白你想去哪里，请再说一遍。';
        case 'I found some likely destinations. Choose one below.':
          return '我找到了一些可能的地点，请选择一个。';
        case 'I could not find more options on other floors.':
          return '我没有找到其它楼层更合适的选项。';
      }
    }
    return english;
  }

  Future<void> _startNavigationFromCandidate(Map<String, dynamic> candidate) async {
    final placeId = (candidate['place'] ?? '').toString();
    final buildingId = (candidate['building'] ?? '').toString();
    final floorId = (candidate['floor'] ?? '').toString();
    final destinationId = candidate['destination_id'].toString();
    final destinationName = (candidate['name'] ?? 'Destination').toString();
    final responseLanguage = _responseLanguage ?? context.read<SettingsProvider>().languageCode;

    if (placeId.isEmpty || buildingId.isEmpty || floorId.isEmpty) {
      _updateStatus('This destination is missing floor context, so I cannot start navigation yet.');
      return;
    }

    final preload = await ApiService.getDestinations(placeId, buildingId, floorId);
    final matched = preload.where((item) => item['id'].toString() == destinationId);
    if (matched.isEmpty) {
      _updateStatus('I found a candidate, but I could not prepare navigation for it.');
      return;
    }

    final selectResp = await ApiService.selectDestination(destinationId);
    if (!mounted) return;
    if (selectResp.containsKey('error')) {
      _updateStatus(selectResp['error'].toString());
      return;
    }

    final announce = _normalizeLanguageCode(responseLanguage, destinationName) == 'zh'
        ? '现在开始为你导航到$destinationName。'
        : _normalizeLanguageCode(responseLanguage, destinationName) == 'th'
            ? 'กำลังเริ่มนำทางไปยัง $destinationName'
            : 'Starting navigation to $destinationName.';
    await HapticFeedback.mediumImpact();
    await TTSService.setLanguage(_normalizeLanguageCode(responseLanguage, announce));
    await TTSService.speakAndWait(announce);
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NavigationScreen(
          selectedPlaceId: placeId,
          selectedPlaceName: placeId,
          selectedBuildingId: buildingId,
          selectedBuildingName: buildingId,
          selectedFloorId: floorId,
          selectedFloorName: floorId,
          selectedDestinationId: destinationId,
          selectedDestinationName: destinationName,
        ),
      ),
    );
  }

  void _updateStatus(String text) {
    if (!mounted) return;
    setState(() {
      _statusText = text;
    });
  }

  bool _isContextualFacilityCategory(String? category) {
    return {
      'restroom',
      'elevator',
      'exit',
      'stairs',
      'service_desk',
    }.contains(category);
  }

  Map<String, dynamic> _applyConversationContext(Map<String, dynamic> query) {
    final category = query['category']?.toString();
    final anchor = _conversationAnchorCandidate;
    if (!_isContextualFacilityCategory(category) || anchor == null) {
      return query;
    }

    final enriched = Map<String, dynamic>.from(query);
    enriched['search_scope'] = 'building';
    if ((enriched['building_hint'] == null || enriched['building_hint'].toString().isEmpty) &&
        anchor['building'] != null) {
      enriched['building_hint'] = anchor['building'];
    }
    if ((enriched['floor_hint'] == null || enriched['floor_hint'].toString().isEmpty) &&
        anchor['floor'] != null) {
      enriched['floor_hint'] = anchor['floor'];
    }
    return enriched;
  }

  Future<Map<String, dynamic>> _resolveDestinationWithConversationContext(
    Map<String, dynamic> destinationQuery, {
    required String responseLanguage,
  }) async {
    final initial = await ApiService.agentResolveDestination(
      destinationQuery,
      responseLanguage: responseLanguage,
    );
    if (initial.containsKey('error')) return initial;

    final candidates = List<Map<String, dynamic>>.from(initial['candidates'] ?? const []);
    final category = destinationQuery['category']?.toString();
    final hasFloorHint = (destinationQuery['floor_hint']?.toString().isNotEmpty ?? false);
    final hasBuildingHint = (destinationQuery['building_hint']?.toString().isNotEmpty ?? false);

    if (candidates.isNotEmpty || !_isContextualFacilityCategory(category)) {
      return initial;
    }

    if (hasFloorHint) {
      final broadenedToBuilding = Map<String, dynamic>.from(destinationQuery)..remove('floor_hint');
      final retried = await ApiService.agentResolveDestination(
        broadenedToBuilding,
        responseLanguage: responseLanguage,
      );
      if (!retried.containsKey('error') &&
          List<Map<String, dynamic>>.from(retried['candidates'] ?? const []).isNotEmpty) {
        _lastDestinationQuery = broadenedToBuilding;
        return retried;
      }
    }

    if (hasBuildingHint) {
      final broadenedToGlobal = Map<String, dynamic>.from(destinationQuery)
        ..remove('floor_hint')
        ..remove('building_hint')
        ..['search_scope'] = 'global';
      final retried = await ApiService.agentResolveDestination(
        broadenedToGlobal,
        responseLanguage: responseLanguage,
      );
      if (!retried.containsKey('error')) {
        _lastDestinationQuery = broadenedToGlobal;
        return retried;
      }
    }

    return initial;
  }

  bool _isAffirmative(String utterance) {
    final normalized = utterance.toLowerCase();
    return [
      'yes',
      'yeah',
      'yep',
      'correct',
      'that one',
      '对',
      '对的',
      '好',
      '好的',
      '是的',
      '想去',
      '去这个',
      '就这个',
      '这个',
      '没错',
      '就是这个',
      '就是它',
      'ใช่',
    ].any(normalized.contains);
  }

  bool _looksLikeSelectionUtterance(String utterance) {
    final normalized = utterance.toLowerCase();
    return [
      'first',
      'second',
      'third',
      'number one',
      'number two',
      'number three',
      'option one',
      'option two',
      'option three',
      '1',
      '2',
      '3',
      '楼',
      'floor',
      '那个',
      '第一个',
      '第二个',
      '第三个',
      'this one',
      'that one',
    ].any(normalized.contains);
  }

  bool _looksLikeBroadenFloorRequest(String utterance) {
    final normalized = utterance.toLowerCase();
    return [
      'other floor',
      'other floors',
      'another floor',
      'different floor',
      'different floors',
      'elsewhere',
      'something else',
      'others',
      '别的楼层',
      '其他楼层',
      '别层',
      '其他层',
      '还有别的',
      '还有其他',
      '别的选项',
      '其他选项',
    ].any(normalized.contains);
  }

  bool _looksLikeFreshDestinationIntent(String utterance) {
    final normalized = utterance.toLowerCase();
    if ([
      'i want to go',
      'i wanna go',
      'i wanna',
      'i want',
      'take me to',
      'bring me to',
      'i need to go',
      'i want restroom',
      'i want bathroom',
      'i need restroom',
      'i need bathroom',
      'i need the restroom',
      'i need the bathroom',
      'i want the restroom',
      'i want the bathroom',
      'i need elevator',
      'i want elevator',
      'i need exit',
      'i want exit',
      '我想去',
      '带我去',
      '我想先去',
      '我想先上',
      '我想上厕所',
      '我想去厕所',
      '我想去洗手间',
      '我想去卫生间',
      '我想去男厕',
      '我想去女厕',
      '我想去电梯',
      '我想去出口',
      '我想找',
      '我要去',
      '我需要去',
      '先去厕所',
      '先去洗手间',
      '先去卫生间',
      '尿急',
      '厕所',
      '洗手间',
      '卫生间',
      '电梯',
      '出口',
      '办公室',
      'ห้องน้ำ',
      'ลิฟต์',
      'ทางออก',
    ].any(normalized.contains)) {
      return true;
    }

    final mentionsFacility = [
      'restroom',
      'bathroom',
      'washroom',
      'toilet',
      'wc',
      'elevator',
      'lift',
      'exit',
      'stairs',
      'stair',
      'service desk',
      'front desk',
      'reception',
      'office',
      '厕',
      '厕所',
      '洗手间',
      '卫生间',
      '电梯',
      '出口',
      '楼梯',
      '服务台',
      '前台',
      '办公室',
      'ห้องน้ำ',
      'ลิฟต์',
      'ทางออก',
    ].any(normalized.contains);

    final soundsLikeNewRequest = [
      'i want',
      'i wanna',
      'i need',
      'take me',
      'bring me',
      'go to',
      'instead',
      'first',
      'rather',
      '先',
      '想',
      '要',
      'ไป',
      'อยาก',
    ].any(normalized.contains);

    return mentionsFacility && soundsLikeNewRequest;
  }

  List<Map<String, dynamic>> _narrowCandidates(
    List<Map<String, dynamic>> candidates,
    String utterance,
  ) {
    final normalized = utterance.toLowerCase();

    int? ordinal;
    if (normalized.contains('first') ||
        normalized.contains('number one') ||
        normalized.contains('option one') ||
        normalized.contains('第一个') ||
        normalized.contains('1')) {
      ordinal = 0;
    }
    if (normalized.contains('second') ||
        normalized.contains('number two') ||
        normalized.contains('option two') ||
        normalized.contains('第二个') ||
        normalized.contains('2')) {
      ordinal = 1;
    }
    if (normalized.contains('third') ||
        normalized.contains('number three') ||
        normalized.contains('option three') ||
        normalized.contains('第三个') ||
        normalized.contains('3')) {
      ordinal = 2;
    }
    if (ordinal != null && ordinal < candidates.length) {
      return [candidates[ordinal]];
    }

    final floorHints = _extractFloorHints(normalized).toSet();
    if (floorHints.isNotEmpty) {
      final floorMatched = candidates.where((candidate) {
        final floor = (candidate['floor'] ?? '').toString().toLowerCase();
        if (floor.isEmpty) return false;
        return floorHints.contains(floor);
      }).toList();
      if (floorMatched.isNotEmpty) {
        return floorMatched;
      }
    }

    final tokens = normalized
        .replaceAll(RegExp(r'[^\w\s\u4e00-\u9fff]'), ' ')
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toSet();

    final filtered = candidates.where((candidate) {
      final haystack = [
        candidate['name'],
        candidate['building'],
        candidate['place'],
        candidate['floor'],
      ].map((part) => (part ?? '').toString().toLowerCase()).join(' ');

      if (_extractFloorHints(normalized).any((hint) => haystack.contains(hint))) {
        return true;
      }

      for (final token in tokens) {
        if (token.length < 2) continue;
        if (haystack.contains(token)) return true;
      }
      return false;
    }).toList();

    return filtered;
  }

  List<Map<String, dynamic>> _resolveSelectedCandidates({
    required List<Map<String, dynamic>> candidates,
    required List<String> selectedIds,
    required String utterance,
  }) {
    var narrowed = candidates
        .where((candidate) => selectedIds.contains(candidate['destination_id'].toString()))
        .toList();
    if (narrowed.length <= 1) {
      return narrowed;
    }

    final refinedByUtterance = _narrowCandidates(narrowed, utterance);
    if (refinedByUtterance.isNotEmpty && refinedByUtterance.length < narrowed.length) {
      narrowed = refinedByUtterance;
    }

    final subtype = _extractRestroomSubtype(utterance);
    if (subtype != null && narrowed.length > 1) {
      final subtypeFiltered = narrowed.where((candidate) {
        final name = (candidate['name'] ?? '').toString().toLowerCase();
        switch (subtype) {
          case 'men':
            return name.contains("men") || name.contains("mens") || name.contains("gentlemen");
          case 'women':
            return name.contains("women") || name.contains("womens") || name.contains("ladies");
          case 'accessible':
            return name.contains("ada") || name.contains("accessible") || name.contains("wheelchair");
          case 'family':
            return name.contains("family") || name.contains("unisex") || name.contains("all gender");
        }
        return false;
      }).toList();
      if (subtypeFiltered.isNotEmpty && subtypeFiltered.length < narrowed.length) {
        narrowed = subtypeFiltered;
      }
    }

    return narrowed;
  }

  String? _extractRestroomSubtype(String utterance) {
    final normalized = utterance.toLowerCase();
    if ([
      '男厕',
      '男洗手间',
      '男卫生间',
      '男厕所',
      'male',
      'men',
      'mens',
      'gentlemen',
      'boys',
    ].any(normalized.contains)) {
      return 'men';
    }
    if ([
      '女厕',
      '女洗手间',
      '女卫生间',
      '女厕所',
      'female',
      'women',
      'womens',
      'ladies',
      'girls',
    ].any(normalized.contains)) {
      return 'women';
    }
    if ([
      'ada',
      'accessible',
      'wheelchair',
      '无障碍',
    ].any(normalized.contains)) {
      return 'accessible';
    }
    if ([
      'family',
      '家庭',
      'unisex',
      'all gender',
    ].any(normalized.contains)) {
      return 'family';
    }
    return null;
  }

  Iterable<String> _extractFloorHints(String utterance) sync* {
    final digitMatches = RegExp(r'(\d+)').allMatches(utterance);
    for (final match in digitMatches) {
      final value = match.group(1);
      if (value == null) continue;
      yield '${value}_floor';
      yield '$value floor';
      yield '$value楼';
    }

    const spokenNumbers = <String, String>{
      'one': '1',
      'first': '1',
      'two': '2',
      'second': '2',
      'three': '3',
      'third': '3',
      'four': '4',
      'fourth': '4',
      'five': '5',
      'fifth': '5',
      'six': '6',
      'sixth': '6',
      'seven': '7',
      'seventh': '7',
      'eight': '8',
      'eighth': '8',
      'nine': '9',
      'ninth': '9',
      'ten': '10',
      'tenth': '10',
      '一': '1',
      '二': '2',
      '两': '2',
      '三': '3',
      '四': '4',
      '五': '5',
      '六': '6',
      '七': '7',
      '八': '8',
      '九': '9',
      '十': '10',
    };

    for (final entry in spokenNumbers.entries) {
      final key = entry.key;
      final value = entry.value;
      final englishFloorPattern = RegExp(r'\b' + RegExp.escape(key) + r'\s+floor\b');
      final chineseFloorPattern = RegExp(RegExp.escape(key) + r'楼');
      if (englishFloorPattern.hasMatch(utterance) || chineseFloorPattern.hasMatch(utterance)) {
        yield '${value}_floor';
        yield '$value floor';
        yield '$value楼';
      }
    }
  }

  String _buildNoMatchSelectionPrompt(String language) {
    final normalized = _normalizeLanguageCode(language, '');
    if (normalized == 'zh') {
      return '我还没从这些选项里听出你指的是哪一个。你可以说楼层，或者直接说第一个、第二个。';
    }
    return 'I still could not tell which option you meant. You can say the floor, or say first, second, or third.';
  }

  String _buildSingleCandidatePrompt(
    Map<String, dynamic> candidate,
    String language,
  ) {
    final normalized = _normalizeLanguageCode(language, '');
    final name = (candidate['name'] ?? '').toString();
    final floor = (candidate['floor'] ?? '').toString().replaceAll('_floor', '');
    final building = (candidate['building'] ?? '').toString();
    if (normalized == 'zh') {
      final parts = [
        if (building.isNotEmpty) building,
        if (floor.isNotEmpty) '$floor楼',
      ];
      return '我理解成$name${parts.isEmpty ? '' : '，在${parts.join('，')}'}。如果对，就再按一次按钮说“对”。';
    }
    final parts = [
      if (building.isNotEmpty) building,
      if (floor.isNotEmpty) 'floor $floor',
    ];
    return 'I think you mean $name${parts.isEmpty ? '' : ' in ${parts.join(', ')}'}. If that is right, press the button again and say yes.';
  }

  String _buildGroupedCandidatePrompt(
    List<Map<String, dynamic>> candidates,
    String language,
  ) {
    final normalized = _normalizeLanguageCode(language, '');
    final firstName = (candidates.first['name'] ?? '').toString();
    final sameName = candidates.every(
      (candidate) => (candidate['name'] ?? '').toString() == firstName,
    );
    if (sameName) {
      final floors = candidates
          .map((candidate) => (candidate['floor'] ?? '').toString().replaceAll('_floor', ''))
          .where((floor) => floor.isNotEmpty)
          .toList();
      final building = (candidates.first['building'] ?? '').toString();
      final place = (candidates.first['place'] ?? '').toString();
      if (normalized == 'zh') {
        return '我找到了${candidates.length}个$firstName，'
            '${building.isNotEmpty ? '都在$building，' : ''}'
            '${place.isNotEmpty && place != building ? '位于$place，' : ''}'
            '分别在${floors.map((floor) => '$floor楼').join('、')}。你可以直接说楼层，或者说第一个、第二个。';
      }
      return 'I found ${candidates.length} $firstName options'
          '${building.isNotEmpty ? ' in $building' : ''}'
          '${place.isNotEmpty && place != building ? ', at $place' : ''}'
          ', on ${floors.map((floor) => 'floor $floor').join(', ')}. '
          'You can say the floor, or say first, second, or third.';
    }

    if (normalized == 'zh') {
      return '我把选项缩小了一些。你可以直接说地点名、楼层，或者说第一个、第二个。';
    }
    return 'I narrowed the options down. You can say the place name, the floor, or just say first, second, or third.';
  }

  String _candidateButtonLabel(Map<String, dynamic> candidate) {
    final siblings = _candidateOptions.where((other) {
      return (other['name'] ?? '').toString() ==
              (candidate['name'] ?? '').toString() &&
          (other['building'] ?? '').toString() ==
              (candidate['building'] ?? '').toString() &&
          (other['place'] ?? '').toString() == (candidate['place'] ?? '').toString();
    }).toList();

    final floor = (candidate['floor'] ?? '').toString();
    final building = (candidate['building'] ?? '').toString();
    final place = (candidate['place'] ?? '').toString();
    final name = (candidate['name'] ?? '').toString();
    final normalizedLanguage =
        _normalizeLanguageCode(_responseLanguage ?? context.read<SettingsProvider>().languageCode, '');

    if (siblings.length > 1 && floor.isNotEmpty) {
      if (normalizedLanguage == 'zh') {
        return '$name · ${floor.replaceAll('_floor', '')}楼';
      }
      return '$name · ${floor.replaceAll('_floor', ' floor')}';
    }

    final parts = [
      if (building.isNotEmpty) building,
      if (place.isNotEmpty && place != building) place,
      if (floor.isNotEmpty) floor.replaceAll('_floor', normalizedLanguage == 'zh' ? '楼' : ' floor'),
    ];
    if (parts.isEmpty) return name;
    return '$name · ${parts.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final orbIntensity = _isListening ? 1.0 : ((_isResolving || _isSpeakingResponse) ? 0.65 : 0.2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Mode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _handleLogout,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              if (_backendStatus != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _backendStatus!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _orbController,
                        builder: (context, _) {
                          final pulse = 1 + (_orbController.value * 0.18 * orbIntensity);
                          final glow = 20 + (40 * orbIntensity) + (40 * _orbController.value * orbIntensity);
                          return Transform.scale(
                            scale: pulse,
                            child: Container(
                              width: 180,
                              height: 180,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    colorScheme.primary.withValues(alpha: 0.95),
                                    colorScheme.primaryContainer.withValues(alpha: 0.85),
                                    colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: colorScheme.primary.withValues(alpha: 0.28),
                                    blurRadius: glow,
                                    spreadRadius: 8 + (18 * orbIntensity),
                                  ),
                                ],
                              ),
                              child: Icon(
                                _isListening
                                    ? Icons.graphic_eq_rounded
                                    : (_isResolving ? Icons.auto_awesome : Icons.mic_none_rounded),
                                size: 72,
                                color: colorScheme.onPrimary,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 28),
                      Text(
                        _statusText,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (_lastHeardText.isNotEmpty && !_isListening)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(
                            _lastHeardText,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_candidateOptions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: _candidateOptions.map((candidate) {
                      return FilledButton.tonal(
                        onPressed: _isResolving
                            ? null
                            : () => _startNavigationFromCandidate(candidate),
                        child: Text(
                          _candidateButtonLabel(candidate),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  onPressed: _isResolving ? null : _toggleVoiceCapture,
                  icon: Icon(_isListening ? Icons.stop_circle_outlined : Icons.mic_rounded),
                  label: Text(_isListening ? 'Stop' : 'Speak to UNav'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
