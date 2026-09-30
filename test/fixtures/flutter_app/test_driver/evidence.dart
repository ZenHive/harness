import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      writeResponseOnFailure: true,
      responseDataCallback: (data) async {
        final directory = Directory(Platform.environment['HARNESS_SCREENSHOT_DIR']!);
        await directory.create(recursive: true);
        final screenshots = data?['screenshots'] as Map<String, dynamic>? ?? {};
        for (final entry in screenshots.entries) {
          if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(entry.key)) {
            throw FormatException('Invalid screenshot name: ${entry.key}');
          }
          await File('${directory.path}/${entry.key}.png')
              .writeAsBytes(base64Decode(entry.value as String));
        }
        await File('${directory.path}/report.json').writeAsString(jsonEncode(data));
      },
    );
