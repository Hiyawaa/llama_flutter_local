import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:math_expressions/math_expressions.dart';

/// A parsed tool-call request emitted by the model, plus (once executed)
/// its result. Kept immutable-ish with copyWithResult for clarity in the
/// ChatProvider streaming flow.
class ToolCallResult {
  final String name;
  final Map<String, dynamic> arguments;
  final String? result;
  final String? error;

  const ToolCallResult({
    required this.name,
    required this.arguments,
    this.result,
    this.error,
  });

  ToolCallResult copyWithResult(String result) => ToolCallResult(
        name: name,
        arguments: arguments,
        result: result,
      );

  ToolCallResult copyWithError(String error) => ToolCallResult(
        name: name,
        arguments: arguments,
        error: error,
      );
}

/// Lightweight, dependency-minimal tool calling for local models that
/// don't have native function-calling support baked into their chat
/// template. We ask the model (via system prompt) to emit a small JSON
/// envelope when it wants to use a tool, parse that envelope defensively,
/// execute the tool locally, and feed the result back as a normal chat
/// turn.
///
/// Deliberately kept to two low-risk, no-auth tools so this doesn't grow
/// into an arbitrary-code-execution surface on a resource-constrained
/// device: a pure-math calculator and a free, keyless weather lookup.
class ToolService {
  final http.Client _client = http.Client();

  static const _toolNames = ['calculator', 'weather'];

  String describeTools() => '''
- calculator: evaluate a math expression. arguments: {"expression": "2 + 2 * 3"}
- weather: get current weather for a place. arguments: {"latitude": 0.0, "longitude": 0.0, "location_name": "..."}''';

  /// Attempts to interpret [content] as a tool-call JSON envelope of the
  /// form {"tool_call": {"name": ..., "arguments": {...}}}. Returns null
  /// if it doesn't parse as one — this is the common case (a normal
  /// answer), so failure here is silent and cheap, not an error.
  ToolCallResult? tryParseToolCall(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('{') || !trimmed.contains('tool_call')) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) return null;
      final call = decoded['tool_call'];
      if (call is! Map<String, dynamic>) return null;
      final name = call['name'] as String?;
      final args = call['arguments'];
      if (name == null || !_toolNames.contains(name)) return null;
      return ToolCallResult(
        name: name,
        arguments: (args is Map<String, dynamic>) ? args : const {},
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> execute(ToolCallResult call) async {
    try {
      switch (call.name) {
        case 'calculator':
          return _runCalculator(call.arguments);
        case 'weather':
          return await _runWeather(call.arguments);
        default:
          return 'Unknown tool: ${call.name}';
      }
    } catch (e) {
      return 'Tool error: $e';
    }
  }

  String _runCalculator(Map<String, dynamic> args) {
    final expr = args['expression']?.toString();
    if (expr == null || expr.trim().isEmpty) {
      return 'Error: no expression provided';
    }
    try {
      final parser = Parser();
      final exp = parser.parse(expr);
      final result = exp.evaluate(EvaluationType.REAL, ContextModel());
      return result.toString();
    } catch (e) {
      return 'Error: could not evaluate "$expr" ($e)';
    }
  }

  Future<String> _runWeather(Map<String, dynamic> args) async {
    final lat = (args['latitude'] as num?)?.toDouble();
    final lon = (args['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      return 'Error: latitude/longitude required';
    }
    // Open-Meteo: free, no API key, generous for low-frequency local use.
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon&current_weather=true',
    );
    final response =
        await _client.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return 'Error: weather service returned ${response.statusCode}';
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final current = data['current_weather'] as Map<String, dynamic>?;
    if (current == null) return 'Error: no weather data available';
    final tempC = current['temperature'];
    final windKph = current['windspeed'];
    return 'Temperature: $tempC°C, Wind: $windKph km/h';
  }

  void dispose() => _client.close();
}
