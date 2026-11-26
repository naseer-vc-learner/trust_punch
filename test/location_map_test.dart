import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trust_punch/src/screens/location_map.dart';

void main() {
  testWidgets('shows each location with its name, circle help and credit',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: LocationMapScreen(
        title: 'Al Wasl Tower',
        lang: 'en',
        points: [
          MapPoint('Gate A', 25.2048, 55.2708),
          MapPoint('Gate B', 25.2270, 55.2708),
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Al Wasl Tower'), findsOneWidget);
    expect(find.text('Gate A'), findsOneWidget);
    expect(find.text('Gate B'), findsOneWidget);
    expect(
      find.text('The circle is the 50 m area where check-in works.'),
      findsOneWidget,
    );
    expect(find.textContaining('OpenStreetMap'), findsWidgets);
  });

  testWidgets('with no locations it says so instead of an empty map',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: LocationMapScreen(title: 'Empty', lang: 'en', points: []),
    ));
    expect(
      find.text('No locations yet. Stand at the site and add it.'),
      findsOneWidget,
    );
  });
}
