import 'package:flutter/material.dart';

void main() => runApp(const FixtureApp());

class FixtureApp extends StatefulWidget {
  const FixtureApp({super.key});

  @override
  State<FixtureApp> createState() => _FixtureAppState();
}

class _FixtureAppState extends State<FixtureApp> {
  int count = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Verification fixture')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const RepaintBoundary(
                  key: ValueKey('color-panel'),
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: ColoredBox(color: Color(0xff1565c0)),
                  ),
                ),
                Text('Count: $count'),
                ElevatedButton(
                  onPressed: () => setState(() => count++),
                  child: const Text('Increment'),
                ),
              ],
            ),
          ),
        ),
      );
}
