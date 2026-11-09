import 'package:flutter/material.dart';

import '../../services/sharing_controller.dart';

/// Placeholder screen wired to [SharingController]. The UI/UX work replaces
/// this; it only needs the controller passed in.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final SharingController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return Scaffold(
          appBar: AppBar(title: Text('DataCast · ${c.deviceName}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(c.folderName ?? 'No folder selected'),
                trailing: TextButton(
                  onPressed: c.isSharing ? null : c.pickFolder,
                  child: const Text('Choose'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.pin),
                title: Text('PIN ${c.pin}'),
                trailing: TextButton(onPressed: c.regeneratePin, child: const Text('New PIN')),
              ),
              if (c.url != null)
                ListTile(
                  leading: const Icon(Icons.link),
                  title: SelectableText(c.url!),
                  subtitle: Text('${c.connectedClients} connected'),
                ),
              ListTile(
                leading: const Icon(Icons.devices),
                title: Text('${c.peers.length} other devices nearby'),
              ),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: c.busy || !c.hasFolder ? null : (c.isSharing ? c.stop : c.start),
                child: Text(c.isSharing ? 'Stop sharing' : 'Start sharing'),
              ),
            ],
          ),
        );
      },
    );
  }
}
