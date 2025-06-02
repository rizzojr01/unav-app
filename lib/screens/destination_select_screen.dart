import 'package:flutter/material.dart';
import '../api/api_service.dart';
import 'navigation_screen.dart';
import 'select_screen.dart';

class DestinationSelectScreen extends StatelessWidget {
  final String selectedPlaceId;
  final String selectedPlaceName;
  final String selectedBuildingId;
  final String selectedBuildingName;
  final String selectedFloorId;
  final String selectedFloorName;

  const DestinationSelectScreen({
    super.key,
    required this.selectedPlaceId,
    required this.selectedPlaceName,
    required this.selectedBuildingId,
    required this.selectedBuildingName,
    required this.selectedFloorId,
    required this.selectedFloorName,
  });

  @override
  Widget build(BuildContext context) {
    return SelectScreen(
      title: "Select Destination",
      promptText: "Please select a destination.",
      fetchOptions: () async {
        // Fetch destinations only once
        final dests = await ApiService.getDestinations(
          selectedPlaceId, selectedBuildingId, selectedFloorId
        );
        // Return names for selection
        return dests.map((e) => e['name'].toString()).toList();
      },
      onSelect: (selectedDestName) async {
        // 1. Fetch the full list (could也可缓存上一步dests变量)
        final dests = await ApiService.getDestinations(
          selectedPlaceId, selectedBuildingId, selectedFloorId
        );
        // 2. Find the selected destination
        final sel = dests.firstWhere((e) => e['name'] == selectedDestName);
        final selectedDestId = sel['id'].toString();

        // 3. Call select_destination on server (does not need user_id)
        final resp = await ApiService.selectDestination(selectedDestId);
        if (resp.containsKey("error")) {
          // Show error dialog and return
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text("Error"),
              content: Text(resp["error"].toString()),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text("OK"),
                ),
              ],
            ),
          );
          return;
        }

        // 4. Navigate to the navigation screen
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NavigationScreen(
              selectedPlaceId: selectedPlaceId,
              selectedPlaceName: selectedPlaceName,
              selectedBuildingId: selectedBuildingId,
              selectedBuildingName: selectedBuildingName,
              selectedFloorId: selectedFloorId,
              selectedFloorName: selectedFloorName,
              selectedDestinationId: selectedDestId,
              selectedDestinationName: selectedDestName,
            ),
          ),
        );
      },
    );
  }
}
