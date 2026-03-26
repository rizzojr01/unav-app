import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// UNav API Service
/// Provides all network methods for registration, login, profile management,
/// email verification, navigation, and resource retrieval.
/// Propagates backend errors as-is for frontend display.
class ApiService {
  static String _server = "http://unav.zapto.org:5001";
  static String? _accessToken;

  /// Set the base URL for the backend server.
  static void setServer(String server) {
    _server = server;
  }

  /// Returns standard headers for JSON requests.
  static Map<String, String> get _jsonHeaders => {
        "Content-Type": "application/json",
        if (_accessToken != null) "Authorization": "Bearer $_accessToken",
      };

  /// Returns headers for multipart/form-data requests.
  static Map<String, String> get _multipartHeaders => {
        if (_accessToken != null) "Authorization": "Bearer $_accessToken",
      };

  // ----------- Auth & Registration -----------

  /// Sends a verification code to the given email address for registration or password reset.
  /// Returns: { "msg": ... } or { "error": ... }
  static Future<Map<String, dynamic>> sendVerificationCode(String email) async {
    final resp = await http.post(
      Uri.parse('$_server/api/send_verification_code'),
      headers: _jsonHeaders,
      body: jsonEncode({"email": email}),
    );
    return _parseResponse(resp);
  }

  /// Registers a new user with email, nickname, password, and verification code.
  /// Returns: { "msg": ..., "id": ... } or { "error": ... }
  static Future<Map<String, dynamic>> register(
    String email,
    String nickname,
    String password,
    String code,
  ) async {
    final resp = await http.post(
      Uri.parse('$_server/api/register'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "email": email,
        "nickname": nickname,
        "password": password,
        "code": code,
      }),
    );
    return _parseResponse(resp);
  }

  /// Authenticates a user using email and password. Stores the access token on success.
  /// Returns: { "access_token": ..., "nickname": ..., ... } or { "error": ... }
  static Future<Map<String, dynamic>> login(
    String email,
    String password,
  ) async {
    final resp = await http.post(
      Uri.parse('$_server/api/login'),
      headers: _jsonHeaders,
      body: jsonEncode({"email": email, "password": password}),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('access_token')) {
      _accessToken = data['access_token'];
    }
    return data;
  }

  /// Logs out the current user and clears the access token.
  /// Returns: { "msg": ... } or { "error": ... }
  static Future<Map<String, dynamic>> logout() async {
    final resp = await http.post(
      Uri.parse('$_server/api/logout'),
      headers: _jsonHeaders,
    );
    _accessToken = null;
    return _parseResponse(resp);
  }

  // ----------- Profile Management -----------

  /// Uploads avatar image to server for the specified email.
  /// Returns: { "url": ... } or { "error": ... }
  static Future<Map<String, dynamic>> uploadAvatar(
    Uint8List imageBytes,
    String filename,
    String email,
  ) async {
    final uri = Uri.parse('$_server/api/upload_avatar');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_multipartHeaders)
      ..fields['email'] = email
      ..files.add(
        http.MultipartFile.fromBytes('file', imageBytes, filename: filename),
      );
    final resp = await request.send();
    final respBody = await resp.stream.bytesToString();
    return jsonDecode(respBody);
  }

  /// Updates the user's nickname by email.
  /// Returns: { "msg": ... } or { "error": ... }
  static Future<Map<String, dynamic>> updateNickname(
    String email,
    String nickname,
  ) async {
    final resp = await http.post(
      Uri.parse('$_server/api/update_nickname'),
      headers: _jsonHeaders,
      body: jsonEncode({"email": email, "nickname": nickname}),
    );
    return _parseResponse(resp);
  }

  // ----------- Password Reset -----------

  /// Sends a verification code for password reset to the user's email.
  /// Returns: { "msg": ... } or { "error": ... }
  static Future<Map<String, dynamic>> sendPasswordResetCode(
    String email,
  ) async {
    final resp = await http.post(
      Uri.parse('$_server/api/send_password_reset_code'),
      headers: _jsonHeaders,
      body: jsonEncode({"email": email}),
    );
    return _parseResponse(resp);
  }

  /// Resets user's password given email, verification code, and new password.
  /// Returns: { "msg": ... } or { "error": ... }
  static Future<Map<String, dynamic>> resetPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    final resp = await http.post(
      Uri.parse('$_server/api/reset_password'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "email": email,
        "code": code,
        "new_password": newPassword,
      }),
    );
    return _parseResponse(resp);
  }

  // ----------- Navigation Data -----------

  /// Fetches the list of available places.
  static Future<List<Map<String, dynamic>>> fetchPlaces() async {
    final resp = await _runTask("get_places", {});
    return List<Map<String, dynamic>>.from(resp["places"] ?? []);
  }

  /// Fetches buildings for a selected place.
  static Future<List<Map<String, dynamic>>> fetchBuildings(
    String placeId,
  ) async {
    final resp = await _runTask("get_buildings", {"place": placeId});
    return List<Map<String, dynamic>>.from(resp["buildings"] ?? []);
  }

  /// Fetches all floors within a building.
  static Future<List<Map<String, dynamic>>> fetchFloors(
    String placeId,
    String buildingId,
  ) async {
    final resp = await _runTask("get_floors", {
      "place": placeId,
      "building": buildingId,
    });
    return List<Map<String, dynamic>>.from(resp["floors"] ?? []);
  }

  /// Fetches navigation destinations on a given floor.
  static Future<List<Map<String, dynamic>>> getDestinations(
    String placeId,
    String buildingId,
    String floorId,
  ) async {
    final resp = await _runTask("get_destinations", {
      "place": placeId,
      "building": buildingId,
      "floor": floorId,
    });
    return List<Map<String, dynamic>>.from(resp["destinations"] ?? []);
  }

  /// Sets the destination for navigation.
  static Future<Map<String, dynamic>> selectDestination(String destId) async {
    return _runTask("select_destination", {"dest_id": destId});
  }

  /// Retrieves the scale value (meters or feet per pixel) for the user's current floor.
  /// Returns { "scale": double } or { "error": ... }
  static Future<double?> getCurrentFloorScale() async {
    final resp = await getScale();
    if (resp.containsKey('scale')) {
      return (resp['scale'] as num).toDouble();
    }
    return null;
  }

  /// Sets the measurement unit for navigation ("feet" or "meter").
  static Future<Map<String, dynamic>> selectUnit(String unit) async {
    return _runTask("select_unit", {"unit": unit});
  }

  /// Sets the user's preferred language for all API responses (to be handled server-side).
  static Future<Map<String, dynamic>> selectLanguage(
    String languageCode,
  ) async {
    return _runTask("select_language", {"language": languageCode});
  }

  /// Sets whether to announce current location during navigation.
  /// Returns: { "msg": ... } or { "error": ... }
  static Future<Map<String, dynamic>> setAnnounceLocation(bool announce) async {
    return _runTask("set_announce_location", {"announce": announce});
  }

  static Future<Map<String, dynamic>> selectTurnMode(String mode) async {
    return _runTask("select_turn_mode", {"turn_mode": mode});
  }

  /// Retrieves the current floorplan as an image (Uint8List).
  static Future<Uint8List?> getFloorplan() async {
    final resp = await _runTask("get_floorplan", {});
    if (resp.containsKey("floorplan")) {
      return base64Decode(resp["floorplan"]);
    }
    return null;
  }

  /// Retrieves the scale information for the current floor.
  static Future<Map<String, dynamic>> getScale() async {
    return _runTask("get_scale", {});
  }

  /// Uploads a query image for localization/navigation and gets the response.
  static Future<Map<String, dynamic>> unavNavigation(
    Uint8List imageBytes,
    String filename,
  ) async {
    final uri = Uri.parse('$_server/api/run_task');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_multipartHeaders)
      ..fields['task'] = "unav_navigation"
      ..fields['inputs'] = "{}"
      ..files.add(
        http.MultipartFile.fromBytes('file', imageBytes, filename: filename),
      );
    final resp = await request.send();
    final respBody = await resp.stream.bytesToString();
    final data = jsonDecode(respBody);

    // Logging Orientation Only
    final pose = data['floorplan_pose'];
    if (pose is Map<String, dynamic>) {
      final orient = pose['ang'] ?? pose['heading'] ?? "N/A";
      print(
        "<<< API RESPONSE [Task: unav_navigation] [Status: ${resp.statusCode}] Orientation: $orient",
      );
    } else {
      print(
        "<<< API RESPONSE [Task: unav_navigation] [Status: ${resp.statusCode}] Orientation: NOT FOUND",
      );
    }

    return data;
  }

  /// Helper for calling unified task-based backend APIs.
  static Future<Map<String, dynamic>> _runTask(
    String task,
    Map<String, dynamic> inputs,
  ) async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({"task": task, "inputs": inputs}),
    );
    return _parseResponse(resp);
  }

  /// Parses HTTP responses, propagating backend errors as { "error": ... }.
  /// Only the backend's "error" or "msg" fields will be shown; otherwise, raw body is shown on error.
  static Map<String, dynamic> _parseResponse(http.Response resp) {
    try {
      final data = jsonDecode(resp.body);

      // If there's an error key, propagate only error string
      if (data is Map<String, dynamic>) {
        if (data.containsKey('error')) {
          return {"error": data['error'].toString()};
        }
        // Also propagate backend 'msg' as error if status is not 2xx (e.g., 201 user_exists)
        if ((resp.statusCode < 200 || resp.statusCode >= 300) &&
            data.containsKey('msg')) {
          return {"error": data['msg'].toString()};
        }
      }
      return data;
    } catch (_) {
      // If JSON decode fails, propagate raw body as error
      return {"error": resp.body};
    }
  }
}
