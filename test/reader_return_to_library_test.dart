import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memoreader/screens/reader/navigation_helper.dart';
import 'package:memoreader/screens/routes.dart';

class DummyLibraryScreen extends StatelessWidget {
  const DummyLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Dummy Library')),
    );
  }
}

class ReturnButtonPage extends StatelessWidget {
  const ReturnButtonPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            returnToLibrary(
              context,
              openLibrary: () => Navigator.of(context).pushReplacementNamed(libraryRoute),
            );
          },
          child: const Text('Return'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('returnToLibrary pops when navigator can pop', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        routes: {
          libraryRoute: (context) => const DummyLibraryScreen(),
        },
        home: const Scaffold(
          body: Center(child: Text('Home Screen')),
        ),
      ),
    );

    navigatorKey.currentState!.push(
      MaterialPageRoute(builder: (context) => const ReturnButtonPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Return'), findsOneWidget);

    await tester.tap(find.text('Return'));
    await tester.pumpAndSettle();

    expect(find.text('Home Screen'), findsOneWidget);
    expect(find.text('Return'), findsNothing);
  });

  testWidgets('returnToLibrary pushes library when navigator cannot pop', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        routes: {
          libraryRoute: (context) => const DummyLibraryScreen(),
        },
        home: const ReturnButtonPage(),
      ),
    );

    expect(find.text('Return'), findsOneWidget);

    await tester.tap(find.text('Return'));
    await tester.pumpAndSettle();

    expect(find.text('Dummy Library'), findsOneWidget);
  });
}
