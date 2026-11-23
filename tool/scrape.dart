import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as htmlparse;
import 'package:http/http.dart' as http;

/// Regenerates `data/dining_options.json` and `data/gym_options.json` in place.
///
/// The JSON files are the registry: every entry's `source` URL says where its
/// `hours` come from. Hand-maintained fields (titles, ids, notices, routes)
/// are preserved verbatim; `hours` and `verified` are rewritten on a
/// successful scrape. On any fetch/parse failure the old values are kept and a
/// warning is printed — a transient upstream error must never nuke good data.
///
/// Run: `dart run tool/scrape.dart`
Future<void> main() async {
  final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  var failures = 0;
  failures += await _refresh('data/dining_options.json', _scrapeDining, today);
  failures += await _refresh('data/gym_options.json', _scrapeGym, today);
  if (failures > 0) {
    stderr.writeln('scrape: $failures entr${failures == 1 ? 'y' : 'ies'} '
        'failed — kept previous values');
  }
}

const _timeout = Duration(seconds: 15);

Future<String> _fetch(String url) async {
  final response = await http.get(Uri.parse(url), headers: const {
    'User-Agent': 'SlugDining-data/1.0 '
        '(+https://github.com/BariBariGood/SlugDining-data)',
  }).timeout(_timeout);
  if (response.statusCode != 200) {
    throw 'HTTP ${response.statusCode}';
  }
  return response.body;
}

/// Applies [scrape] to each entry with a `source`, preserving old hours on
/// failure. Returns the number of failed entries.
Future<int> _refresh(
  String path,
  Map<String, List<Map<String, num>>> Function(String html) scrape,
  String today,
) async {
  final file = File(path);
  final entries = (json.decode(await file.readAsString()) as List)
      .cast<Map<String, dynamic>>();
  var failures = 0;

  for (final entry in entries) {
    final source = entry['source'] as String?;
    if (source == null) continue;
    try {
      final html = await _fetch(source);
      final hours = scrape(html);
      entry['hours'] = hours;
      entry['verified'] = today;
      stdout.writeln('scrape: ${entry['title']} ok');
    } catch (e) {
      failures++;
      stderr.writeln('scrape: ${entry['title']} FAILED ($e) — kept old hours');
    }
  }

  const encoder = JsonEncoder.withIndent('  ');
  await file.writeAsString('${encoder.convert(entries)}\n');
  return failures;
}

const _dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

Map<String, List<Map<String, num>>> _emptyWeek() =>
    {for (final d in _dayKeys) d: <Map<String, num>>[]};

/// Parses dining.ucsc.edu `itemprop="openingHours"` metas like
/// `content="Tu-Fr 8:00-22:00"`. Throws when no day coverage is recognized —
/// an all-`[]` week is only valid if the source actually marks every day
/// closed.
Map<String, List<Map<String, num>>> _scrapeDining(String html) {
  final document = htmlparse.parse(html);
  final metas = document.querySelectorAll('meta[itemprop="openingHours"]');
  final week = _emptyWeek();
  final seen = <String>{};
  var parsed = 0;

  for (final meta in metas) {
    final content = meta.attributes['content'];
    if (content == null || !seen.add(content)) continue;
    final match =
        RegExp(r'^([A-Za-z]{2})(?:-([A-Za-z]{2}))?\s+(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})')
            .firstMatch(content.trim());
    if (match == null) continue;

    final startIdx = _dayIndex(match.group(1)!);
    final endIdx = _dayIndex(match.group(2) ?? match.group(1)!);
    if (startIdx < 0 || endIdx < 0 || endIdx < startIdx) continue;

    final open = _hour(match.group(3)!, match.group(4)!);
    var close = _hour(match.group(5)!, match.group(6)!);
    if (close == 0) close = 24; // midnight close, not "same instant as open"
    if (close <= open) continue;

    for (var d = startIdx; d <= endIdx; d++) {
      week[_dayKeys[d]]!.add({'open': open, 'close': close});
    }
    parsed++;
  }
  if (parsed == 0) throw 'no openingHours metas parsed';
  return week;
}

int _dayIndex(String abbrev) => const {
      'Mo': 0,
      'Tu': 1,
      'We': 2,
      'Th': 3,
      'Fr': 4,
      'Sa': 5,
      'Su': 6,
    }[abbrev] ??
    -1;

num _hour(String h, String m) => int.parse(h) + int.parse(m) / 60;

/// Parses a Campus Rec `GetFacility` "Regular Facility Hours" card:
/// `<strong>Monday:</strong>` in one `<p>` followed by `8:00 AM - 8:00 PM`,
/// `7:30 - 11:00 PM` (start inherits the end's AM/PM), or `Closed` in the
/// next. Every recognized day row counts toward success — a facility that is
/// "Closed" all week is valid data (EFH Pool during the remodel).
Map<String, List<Map<String, num>>> _scrapeGym(String html) {
  final document = htmlparse.parse(html);
  final week = _emptyWeek();

  final titles = document.querySelectorAll('h2.card-title');
  final card = titles
      .where((t) => t.text.toLowerCase().contains('hours'))
      .map((t) => t.parent)
      .firstOrNull;
  if (card == null) throw 'no hours card on page';

  var parsed = 0;
  final paragraphs = card.querySelectorAll('p');
  for (var i = 0; i + 1 < paragraphs.length; i++) {
    final strong = paragraphs[i].querySelector('strong');
    if (strong == null) continue;
    final dayName = strong.text.trim().replaceAll(':', '');
    final dayIdx = _fullDayIndex(dayName);
    if (dayIdx < 0) continue;
    parsed++;
    i++; // consumed the value paragraph

    final value = paragraphs[i].text.trim();
    final match = RegExp(
            r'(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?\s*-\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)',
            caseSensitive: false)
        .firstMatch(value);
    if (match == null) continue; // "Closed", "By Reservation", etc.

    final open =
        _to24(match.group(1)!, match.group(2), match.group(3) ?? match.group(6)!);
    var close = _to24(match.group(4)!, match.group(5), match.group(6)!);
    if (close == 0) close = 24; // "12:00 AM" close means end of day
    if (close <= open) continue;
    week[_dayKeys[dayIdx]]!.add({'open': open, 'close': close});
  }
  if (parsed == 0) throw 'no day rows parsed';
  return week;
}

int _fullDayIndex(String name) => const {
      'Monday': 0,
      'Tuesday': 1,
      'Wednesday': 2,
      'Thursday': 3,
      'Friday': 4,
      'Saturday': 5,
      'Sunday': 6,
    }[name] ??
    -1;

num _to24(String h, String? m, String ampm) {
  var hour = int.parse(h);
  if (ampm.toUpperCase() == 'PM' && hour != 12) hour += 12;
  if (ampm.toUpperCase() == 'AM' && hour == 12) hour = 0;
  return hour + (int.tryParse(m ?? '0') ?? 0) / 60;
}
