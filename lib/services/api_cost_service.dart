import 'package:shared_preferences/shared_preferences.dart';

class ApiCostService {
  static const String _costKey = 'api_cost_total_usd';
  
  // Pricing for gpt-4o-mini (as of the knowledge cutoff)
  // Input: $0.150 per 1M tokens
  // Output: $0.600 per 1M tokens
  static const double _inputCostPer1MTokens = 0.150;
  static const double _outputCostPer1MTokens = 0.600;
  
  /// Add cost for an API call
  /// Returns the cost in USD
  Future<double> addCost({
    required int inputTokens,
    required int outputTokens,
  }) async {
    try {
      final inputCost = (inputTokens / 1000000) * _inputCostPer1MTokens;
      final outputCost = (outputTokens / 1000000) * _outputCostPer1MTokens;
      final totalCost = inputCost + outputCost;
      
      final currentTotal = await getTotalCost();
      final newTotal = currentTotal + totalCost;
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_costKey, newTotal);
      
      return totalCost;
    } catch (e) {
      // If error, don't crash - cost tracking is not critical
      return 0.0;
    }
  }
  
  /// Get total accumulated cost
  Future<double> getTotalCost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_costKey) ?? 0.0;
    } catch (e) {
      return 0.0;
    }
  }
  
  /// Reset cost counter
  Future<void> resetCost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_costKey, 0.0);
    } catch (e) {
      // Ignore errors
    }
  }
  
  /// Estimate cost from token counts (for display purposes)
  double estimateCost(int inputTokens, int outputTokens) {
    final inputCost = (inputTokens / 1000000) * _inputCostPer1MTokens;
    final outputCost = (outputTokens / 1000000) * _outputCostPer1MTokens;
    return inputCost + outputCost;
  }
}

