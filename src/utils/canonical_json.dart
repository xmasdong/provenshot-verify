import 'dart:convert';

/// Deterministic ("canonical") JSON serialization used as the message that is
/// hashed and signed. The exact same bytes MUST be reproducible at verify time
/// (and by a future web verifier), so:
///  - object keys are sorted lexicographically (recursively),
///  - no insignificant whitespace,
///  - null values are kept (so the schema is fully bound),
///  - numbers are emitted by [jsonEncode]; capture-time code rounds doubles to a
///    fixed precision before storing so the textual form is stable.
String canonicalJsonEncode(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(value, buffer);
  return buffer.toString();
}

void _writeCanonical(Object? value, StringBuffer out) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      out.write(jsonEncode(keys[i]));
      out.write(':');
      _writeCanonical(value[keys[i]], out);
    }
    out.write('}');
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeCanonical(value[i], out);
    }
    out.write(']');
  } else {
    // Strings, numbers, booleans, null.
    out.write(jsonEncode(value));
  }
}
