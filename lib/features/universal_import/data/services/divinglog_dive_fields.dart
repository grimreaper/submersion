import 'package:submersion/features/universal_import/data/services/divemate_values.dart';
import 'package:submersion/features/universal_import/data/services/divinglog_place_values.dart';
import 'package:submersion/features/universal_import/data/services/divinglog_raw_types.dart';

/// Optional Dive Log fields. Text parsers are shared with DiveMate, but
/// source-specific codes and column names are kept separate.
abstract final class DivingLogDiveFields {
  static void apply(
    Map<String, dynamic> dive,
    DivingLogRawDive raw,
    DivingLogLogbook book,
  ) {
    if (book.isDiveMate) return;
    final notes = <String>[];
    final waterCode = raw.waterCode == null || raw.waterCode == 0
        ? book.placesById[raw.placeId]?.water
        : raw.waterCode;
    final water = DivingLogPlaceValues.waterType(waterCode);
    if (water != null) {
      dive['waterType'] = water.name;
    } else if (waterCode == 4) {
      notes.add('Water type: Chlorinated');
    } else if (waterCode != null && waterCode != 0) {
      notes.add('Water type (Dive Log): $waterCode');
    }
    final rating = DiveMateValues.rating(raw.rating);
    if (rating != null) {
      dive['rating'] = rating;
    } else if (raw.rating != null && raw.rating != 0) {
      notes.add('Rating (Dive Log): ${raw.rating}');
    }
    final entry = switch (raw.entryCode) {
      1 => 'shore',
      2 => 'boat',
      5 => 'jetty',
      _ => null,
    };
    if (entry != null) {
      dive['entryMethod'] = entry;
    } else if (raw.entryCode == 3) {
      // Submersion has no Pool entry method.
      notes.add('Entry type: Pool');
    } else if (raw.entryCode != null && raw.entryCode != 0) {
      notes.add('Entry type (Dive Log): ${raw.entryCode}');
    }
    if (raw.weather != null) dive['weatherDescription'] = raw.weather;
    if (raw.surface != null) dive['surfaceConditions'] = raw.surface;
    if (raw.boat != null) dive['boatName'] = raw.boat;
    final current = DiveMateValues.current(raw.current);
    if (current != null) {
      dive['currentStrength'] = current.name;
    } else if (raw.current != null) {
      notes.add('Current: ${raw.current}');
    }
    final visibility = DiveMateValues.visibility(raw.horizontalVisibility);
    if (visibility.meters != null) {
      dive['visibilityMeters'] = visibility.meters;
    } else if (visibility.level != null) {
      dive['visibility'] = visibility.level!.name;
    } else if (visibility.text != null) {
      notes.add('Visibility: ${visibility.text}');
    }
    final interval = DiveMateValues.surfaceInterval(raw.surfaceInterval);
    if (interval != null) {
      dive['surfaceInterval'] = interval;
    } else if (raw.surfaceInterval != null && raw.surfaceInterval != '00:00') {
      notes.add('Surface interval: ${raw.surfaceInterval}');
    }

    // Dive Log also uses Altitude for measured pressure, with an mbar unit.
    final altitude = raw.altitude?.trim();
    if (altitude != null) {
      final pressureMatch = RegExp(
        r'^(\d+(?:[.,]\d+)?)\s*mbar$',
        caseSensitive: false,
      ).firstMatch(altitude);
      final pressure = pressureMatch == null
          ? null
          : double.tryParse(pressureMatch.group(1)!.replaceAll(',', '.'));
      final height = DivingLogPlaceValues.altitudeMeters(altitude);
      if (pressure != null && pressure.isFinite && pressure > 0) {
        dive['surfacePressure'] = pressure / 1000;
      } else if (height != null) {
        dive['altitude'] = height;
      } else {
        notes.add('Altitude / surface pressure: $altitude');
      }
    }

    final supply = int.tryParse(raw.supplyType ?? '');
    // Dive Log also exports an unset supply type as code 5.
    if (supply != null && supply != 0 && supply != 5) {
      notes.add('Supply type (Dive Log): $supply');
    }
    final gas = raw.gasDescription?.trim();
    if (gas != null && gas.isNotEmpty) {
      final factors = RegExp(
        r'^(ZHL-16[ABC])\s+GF:\s*(\d{1,3})\s*/\s*(\d{1,3})$',
        caseSensitive: false,
      ).firstMatch(gas);
      final low = factors == null ? null : int.parse(factors.group(2)!);
      final high = factors == null ? null : int.parse(factors.group(3)!);
      if (gas.toLowerCase() == 'gauge') {
        dive['diveMode'] = 'gauge';
      } else if (low != null &&
          high != null &&
          low > 0 &&
          low <= high &&
          high <= 100) {
        dive['decoAlgorithm'] = factors!.group(1)!.toUpperCase();
        dive['gradientFactorLow'] = low;
        dive['gradientFactorHigh'] = high;
      } else {
        notes.add('Gas / computer settings: $gas');
      }
    }
    if (notes.isNotEmpty) {
      dive['notes'] = [
        if (dive['notes'] case final String previous when previous.isNotEmpty)
          previous,
        notes.join('\n'),
      ].join('\n\n');
    }
  }
}
