import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// UNav API Service
/// Provides all necessary methods to interact with the UNav server backend.
/// All endpoints are asynchronous and return parsed JSON objects or lists.
/// All methods throw an Exception on unexpected server errors.
class ApiService {
  static String _server = "http://unav.zapto.org:5001";
  static void setServer(String server) {
    _server = server;
  }
  static String? _accessToken;

  /// Returns headers for standard JSON requests, including Authorization if logged in.
  static Map<String, String> get _jsonHeaders => {
        "Content-Type": "application/json",
        if (_accessToken != null) "Authorization": "Bearer $_accessToken",
      };

  /// Returns headers for multipart/form-data requests.
  static Map<String, String> get _multipartHeaders => {
        if (_accessToken != null) "Authorization": "Bearer $_accessToken",
      };

  /// Registers a new user.
  static Future<Map<String, dynamic>> register(String username, String password) async {
    final resp = await http.post(
      Uri.parse('$_server/api/register'),
      headers: _jsonHeaders,
      body: jsonEncode({"username": username, "password": password}),
    );
    return _parseResponse(resp);
  }

  /// Logs in with username and password. Saves access token for further requests.
  static Future<Map<String, dynamic>> login(String username, String password) async {
    final resp = await http.post(
      Uri.parse('$_server/api/login'),
      headers: _jsonHeaders,
      body: jsonEncode({"username": username, "password": password}),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('access_token')) {
      _accessToken = data['access_token'];
    }
    return data;
  }

  /// Logs out current user and clears the token.
  static Future<Map<String, dynamic>> logout() async {
    final resp = await http.post(
      Uri.parse('$_server/api/logout'),
      headers: _jsonHeaders,
    );
    _accessToken = null;
    return _parseResponse(resp);
  }

  /// Fetches the list of available places.
  /// Returns: List of {"name": ..., "id": ...}
  static Future<List<Map<String, dynamic>>> fetchPlaces() async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "get_places",
        "inputs": {}
      }),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('places')) {
      return List<Map<String, dynamic>>.from(data['places']);
    }
    return [];
  }

  /// Fetches the list of buildings for a given place.
  /// Returns: List of {"name": ..., "id": ...}
  static Future<List<Map<String, dynamic>>> fetchBuildings(String placeId) async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "get_buildings",
        "inputs": {"place": placeId}
      }),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('buildings')) {
      return List<Map<String, dynamic>>.from(data['buildings']);
    }
    return [];
  }

  /// Fetches the list of floors for a given building.
  /// Returns: List of {"name": ..., "id": ...}
  static Future<List<Map<String, dynamic>>> fetchFloors(String placeId, String buildingId) async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "get_floors",
        "inputs": {"place": placeId, "building": buildingId}
      }),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('floors')) {
      return List<Map<String, dynamic>>.from(data['floors']);
    }
    return [];
  }

  /// Fetches the list of destinations for a given floor.
  /// Returns: List of {"name": ..., "id": ...}
  static Future<List<Map<String, dynamic>>> getDestinations(
    String placeId, String buildingId, String floorId) async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "get_destinations",
        "inputs": {
          "place": placeId,
          "building": buildingId,
          "floor": floorId
        }
      }),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('destinations')) {
      return List<Map<String, dynamic>>.from(data['destinations']);
    }
    return [];
  }

  /// Selects a destination by ID.
  static Future<Map<String, dynamic>> selectDestination(String destId) async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "select_destination",
        "inputs": {"dest_id": destId}
      }),
    );
    return _parseResponse(resp);
  }

  /// Selects preferred unit (e.g. "feet" or "meter").
  static Future<Map<String, dynamic>> selectUnit(String unit) async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "select_unit",
        "inputs": {"unit": unit}
      }),
    );
    return _parseResponse(resp);
  }

  /// Retrieves the current floorplan image as binary data (Uint8List).
  static Future<Uint8List?> getFloorplan() async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "get_floorplan",
        "inputs": {}
      }),
    );
    final data = _parseResponse(resp);
    if (data.containsKey('floorplan')) {
      return base64Decode(data['floorplan']);
    }
    return null;
  }

  /// Retrieves the scale information for the current floor.
  static Future<Map<String, dynamic>> getScale() async {
    final resp = await http.post(
      Uri.parse('$_server/api/run_task'),
      headers: _jsonHeaders,
      body: jsonEncode({
        "task": "get_scale",
        "inputs": {}
      }),
    );
    return _parseResponse(resp);
  }

  /// Uploads a query image for localization and navigation.
  /// Returns the server response as a JSON map.
  static Future<Map<String, dynamic>> unavNavigation(Uint8List imageBytes, String filename) async {
    final uri = Uri.parse('$_server/api/run_task');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_multipartHeaders)
      ..fields['task'] = "unav_navigation"
      ..fields['inputs'] = "{}"
      ..files.add(
        http.MultipartFile.fromBytes(
          'file', imageBytes,
          filename: filename,
        ),
      );
    final resp = await request.send();
    final respBody = await resp.stream.bytesToString();
    return jsonDecode(respBody);
  }

  /// Internal utility to parse HTTP responses.
  /// Throws Exception on unexpected status.
  static Map<String, dynamic> _parseResponse(http.Response resp) {
    if (resp.statusCode == 200 || resp.statusCode == 400) {
      return jsonDecode(resp.body);
    } else {
      throw Exception("HTTP ${resp.statusCode}: ${resp.body}");
    }
  }
}
