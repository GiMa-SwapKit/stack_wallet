import 'package:decimal/decimal.dart';

/// SwapKit returns amounts as decimal strings, but be lenient with numbers.
Decimal? skDecimalOrNull(dynamic value) {
  if (value == null) return null;
  return Decimal.tryParse(value.toString());
}

String? skStringOrNull(dynamic value) {
  if (value == null) return null;
  final s = value.toString();
  return s.isEmpty ? null : s;
}

final _hexAddress = RegExp(r"^0[xX][0-9a-fA-F]+$");

/// Lowercases hex contract addresses, which are case-insensitive. Any other
/// format is returned unchanged.
String? skNormalizeContract(String? address) {
  if (address == null || address.isEmpty) return null;
  return _hexAddress.hasMatch(address) ? address.toLowerCase() : address;
}

Map<String, dynamic>? skMapOrNull(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<Map<String, dynamic>> skMapList(dynamic value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
    : const [];
