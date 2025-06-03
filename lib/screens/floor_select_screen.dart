import 'package:flutter/material.dart';
import '../api/api_service.dart';
import 'destination_select_screen.dart';
import 'select_screen.dart';

class FloorSelectScreen extends StatelessWidget {
  final String selectedPlaceId;
  final String selectedPlaceName;
  final String selectedBuildingId;
  final String selectedBuildingName;
  const FloorSelectScreen({
    super.key,
    required this.selectedPlaceId,
    required this.selectedPlaceName,
    required this.selectedBuildingId,
    required this.selectedBuildingName,
  });

  @override
  Widget build(BuildContext context) {
    return SelectScreen(
      title: "Select Floor",
      selectionType: "floor",
      fetchOptions: () async {
        final floors = await ApiService.fetchFloors(selectedPlaceId, selectedBuildingId);
        return floors.map((e) => e['name'].toString()).toList();
      },
      onSelect: (selectedFloorName) async {
        final floors = await ApiService.fetchFloors(selectedPlaceId, selectedBuildingId);
        final sel = floors.firstWhere((e) => e['name'] == selectedFloorName);
        final selectedFloorId = sel['id'];
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DestinationSelectScreen(
              selectedPlaceId: selectedPlaceId,
              selectedPlaceName: selectedPlaceName,
              selectedBuildingId: selectedBuildingId,
              selectedBuildingName: selectedBuildingName,
              selectedFloorId: selectedFloorId,
              selectedFloorName: selectedFloorName,
            ),
          ),
        );
      },
    );
  }
}
