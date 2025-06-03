import 'package:flutter/material.dart';
import '../api/api_service.dart';
import 'building_select_screen.dart';
import 'select_screen.dart';

class PlaceSelectScreen extends StatelessWidget {
  const PlaceSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SelectScreen(
      title: "Select Place",
      selectionType: "place",
      fetchOptions: () async {
        final places = await ApiService.fetchPlaces();
        return places.map((e) => e['name'].toString()).toList();
      },
      onSelect: (selectedPlaceName) async {
        final places = await ApiService.fetchPlaces();
        final sel = places.firstWhere((e) => e['name'] == selectedPlaceName);
        final selectedPlaceId = sel['id'];
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BuildingSelectScreen(
              selectedPlaceId: selectedPlaceId,
              selectedPlaceName: selectedPlaceName,
            ),
          ),
        );
      },
    );
  }
}
