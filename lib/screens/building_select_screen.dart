import 'package:flutter/material.dart';
import '../api/api_service.dart';
import 'floor_select_screen.dart';
import 'select_screen.dart';

class BuildingSelectScreen extends StatelessWidget {
  final String selectedPlaceId;
  final String selectedPlaceName;
  const BuildingSelectScreen({
    super.key,
    required this.selectedPlaceId,
    required this.selectedPlaceName,
  });

  @override
  Widget build(BuildContext context) {
    return SelectScreen(
      title: "Select Building",
      selectionType: "building",
      fetchOptions: () async {
        final buildings = await ApiService.fetchBuildings(selectedPlaceId);
        return buildings.map((e) => e['name'].toString()).toList();
      },
      onSelect: (selectedBuildingName) async {
        final buildings = await ApiService.fetchBuildings(selectedPlaceId);
        final sel = buildings.firstWhere((e) => e['name'] == selectedBuildingName);
        final selectedBuildingId = sel['id'];
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FloorSelectScreen(
              selectedPlaceId: selectedPlaceId,
              selectedPlaceName: selectedPlaceName,
              selectedBuildingId: selectedBuildingId,
              selectedBuildingName: selectedBuildingName,
            ),
          ),
        );
      },
    );
  }
}
