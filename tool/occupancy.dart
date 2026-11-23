import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as htmlparse;
import 'package:http/http.dart' as http;

/// Appends one Campus Rec occupancy snapshot to
/// `data/gym_occupancy_history.json` (rolling 7-day window).
///
/// Format matches the app's on-device history file:
/// `{ "<cleaned facility name>": [[epochMs, current, max], ...], ... }`.
/// The app merges this feed with its own samples — facility names are
/// normalized the same way (`cleanName`) so keys line up.
///
/// Run: `dart run tool/occupancy.dart`
Future<void> main() async {
  final response = await http.get(
    Uri.parse('https://campusrec.ucsc.edu/FacilityOccupancy'),
    headers: const {
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
    },
  ).timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    stderr.writeln('occupancy: HTTP ${response.statusCode} — keeping old data');
    return;
  }

  final snapshot = parseSnapshot(response.body);
  if (snapshot.isEmpty) {
    stderr.writeln('occupancy: no facilities parsed — keeping old data');
    return;
  }

  final file = File('data/gym_occupancy_history.json');
  final history = <String, List<List<num>>>{};
  if (await file.exists()) {
    (json.decode(await file.readAsString()) as Map).forEach((k, v) =>
        history[k] = [for (final s in v as List) (s as List).cast<num>()]);
  }

  final now = DateTime.now();
  final cutoff = now.subtract(const Duration(days: 7));
  for (final entry in snapshot.entries) {
    final samples = history.putIfAbsent(entry.key, () => []);
    samples.add([now.millisecondsSinceEpoch, entry.value.$1, entry.value.$2]);
    samples.removeWhere(
        (s) => DateTime.fromMillisecondsSinceEpoch(s[0].toInt())
            .isBefore(cutoff));
  }

  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(
      Map.fromEntries(
          history.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))));
  stdout.writeln('occupancy: recorded ${snapshot.length} facilities at $now');
}

/// Parses the FacilityOccupancy page into `{name: (current, max)}`.
Map<String, (int, int)> parseSnapshot(String body) {
  final document = htmlparse.parse(body);
  final out = <String, (int, int)>{};
  for (final facility in document.querySelectorAll('.occupancy-card-body')) {
    final name = cleanName(facility.previousElementSibling?.text ?? '');
    if (name.isEmpty) continue;
    final max = int.tryParse(facility
            .querySelector('.max-occupancy')
            ?.text
            .split(':')
            .last
            .trim() ??
        '0') ?? 0;
    final current = int.tryParse(
            facility.querySelector('.occupancy-count strong')?.text.trim() ??
                '0') ?? 0;
    out[name] = (current, max);
  }
  return out;
}

/// Keeps parity with the app's `GymOccupancyData.cleanName` — collapses
/// whitespace and strips the embedded "more_vert ... Details" widget text.
String cleanName(String name) => name
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'more_vert.*Details'), '')
    .trim();
