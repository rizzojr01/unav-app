import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class DebugImageScreen extends StatelessWidget {
  const DebugImageScreen({super.key});

  // These are the images identified in assets/node_images
  static const List<String> nodeImages = [
    "Node1_E.jpg", "Node1_N.jpg", "Node1_S.jpg", "Node1_W.jpg",
    "Node2_E.jpg", "Node2_N.jpg", "Node2_S.jpg", "Node2_W.jpg",
    "Node3_E.jpg", "Node3_N.jpg", "Node3_S.jpg", "Node3_W.jpg",
    "Node4_E.jpg", "Node4_N.jpg", "Node4_S.jpg", "Node4_W.jpg",
    "Node5_E.jpg", "Node5_N.jpg", "Node5_S.jpg", "Node5_W.jpg",
    "Node6_E.jpg", "Node6_N.jpg", "Node6_S.jpg", "Node6_W.jpg",
    "Node7_E.jpg", "Node7_N.jpg", "Node7_S.jpg", "Node7_W.jpg",
    "Node8_E.jpg", "Node8_N.jpg", "Node8_S.jpg", "Node8_W.jpg",
    "Node9_E.jpg", "Node9_N.jpg", "Node9_S.jpg", "Node9_W.jpg",
    "Node10_E.jpg", "Node10_N.jpg", "Node10_S.jpg", "Node10_W.jpg",
    "Node11_E.jpg", "Node11_N.jpg", "Node11_S.jpg", "Node11_W.jpg",
    "Node12_E.jpg", "Node12_N.jpg", "Node12_S.jpg", "Node12_W.jpg",
    "Node13_E.jpg", "Node13_N.jpg", "Node13_S.jpg", "Node13_W.jpg",
    "Node14_E.jpg", "Node14_N.jpg", "Node14_S.jpg", "Node14_W.jpg",
    "Node15_E.jpg", "Node15_N.jpg", "Node15_S.jpg", "Node15_W.jpg",
    "Node16_E.jpg", "Node16_N.jpg", "Node16_S.jpg", "Node16_W.jpg",
    "Node17_E.jpg", "Node17_N.jpg", "Node17_S.jpg", "Node17_W.jpg",
    "Node18_E.jpg", "Node18_N.jpg", "Node18_S.jpg", "Node18_W.jpg",
    "Node19_E.jpg", "Node19_N.jpg", "Node19_S.jpg", "Node19_W.jpg",
    "Node20_E.jpg", "Node20_N.jpg", "Node20_S.jpg", "Node20_W.jpg",
  ];

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Node Images Debug'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.green,
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text(
              'Use Debug Image', 
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
            ),
            subtitle: const Text(
              'Overrides camera frames with selected asset during navigation.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            activeColor: Colors.green,
            value: settings.useDebugImage,
            onChanged: (val) => settings.setDebugImageEnabled(val),
          ),
          const Divider(color: Colors.white10),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.8,
              ),
              itemCount: nodeImages.length,
              itemBuilder: (context, index) {
                final imageName = nodeImages[index];
                final assetPath = 'assets/node_images/$imageName';
                final isSelected = settings.debugAssetPath == assetPath;

                return GestureDetector(
                  onTap: () => settings.setDebugAssetPath(assetPath),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? Colors.green : Colors.white10,
                        width: isSelected ? 3 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.asset(
                          assetPath,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => const Center(
                            child: Icon(Icons.error, color: Colors.red),
                          ),
                        ),
                        if (isSelected)
                          const Positioned(
                            top: 8,
                            right: 8,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.green,
                              child: Icon(Icons.check, size: 16, color: Colors.black),
                            ),
                          ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            child: Text(
                              imageName,
                              style: const TextStyle(color: Colors.white, fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
