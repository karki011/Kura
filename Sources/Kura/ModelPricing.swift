// ModelPricing — per-model list prices and cost math for per-answer cost display.
// Pure functions, no network: unit-tested with recorded usage.
import Foundation

enum ModelPricing {
    /// USD per 1M tokens. `cachedInput` applies to LLMUsage.cachedInputTokens; audio
    /// rates apply to the realtime engine's audio token split (nil for text-only models).
    struct Rate: Equatable, Sendable {
        var input: Double
        var output: Double
        var cachedInput: Double?
        var audioInput: Double?
        var audioOutput: Double?
    }

    // List prices per 1M tokens, standard tier, checked 2026-09-12 against the
    // OpenAI and Anthropic pricing pages (aggregated copies consulted):
    //   https://www.morphllm.com/openai-api-pricing (2026-08-21)
    //   https://www.aipricing.guru/kimi-k2-7-code-pricing-vs-gpt-5-5/ (2026-08-31)
    //   https://aicatchup.com/news/gpt-realtime-2-1-mini-api (2026-08-03, quoting OpenAI)
    //   https://openrouter.ai/anthropic/claude-haiku-4.5 (2026-09-09)
    //   https://www.metacto.com/blogs/anthropic-api-pricing-a-full-breakdown-of-costs-and-integration
    // OpenAI "priority" service tier (Fast mode) bills differently; until the exact
    // premium is pinned down, priority requests are estimated at standard rates.
    // Order matters: the first matching prefix wins, so specific prefixes come first.
    private static let table: [(prefix: String, rate: Rate)] = [
        ("gpt-5-nano", Rate(input: 0.05, output: 0.40, cachedInput: 0.005)),
        ("gpt-5-mini", Rate(input: 0.25, output: 2.00, cachedInput: 0.025)),
        ("gpt-5.5-pro", Rate(input: 30.00, output: 180.00)),
        ("gpt-5.5", Rate(input: 5.00, output: 30.00, cachedInput: 0.50)),
        ("gpt-5.6", Rate(input: 5.00, output: 30.00, cachedInput: 0.50)),
        ("gpt-5.4", Rate(input: 2.50, output: 15.00, cachedInput: 0.25)),
        ("gpt-5", Rate(input: 1.25, output: 10.00, cachedInput: 0.125)),
        ("gpt-realtime-mini", Rate(input: 0.60, output: 2.40, cachedInput: 0.06, audioInput: 10.00, audioOutput: 20.00)),
        ("gpt-realtime", Rate(input: 4.00, output: 24.00, cachedInput: 0.40, audioInput: 32.00, audioOutput: 64.00)),
        ("claude-opus-4.5", Rate(input: 5.00, output: 25.00, cachedInput: 0.50)),
        ("claude-opus-4", Rate(input: 15.00, output: 75.00, cachedInput: 1.50)),
        ("claude-sonnet-4", Rate(input: 3.00, output: 15.00, cachedInput: 0.30)),
        ("claude-haiku-4", Rate(input: 1.00, output: 5.00, cachedInput: 0.10)),
    ]

    static func pricePerMTok(model: String) -> Rate? {
        table.first { model.hasPrefix($0.prefix) }?.rate
    }

    /// Estimated USD for one call. nil when the model is unknown — the UI then shows
    /// tokens only. Audio tokens without a known audio rate are simply unpriced.
    static func cost(for usage: LLMUsage, model: String) -> Double? {
        guard let rate = pricePerMTok(model: model) else { return nil }
        var usd = Double(usage.inputTokens) * rate.input + Double(usage.outputTokens) * rate.output
        if let cached = usage.cachedInputTokens {
            usd += Double(cached) * (rate.cachedInput ?? rate.input)
        }
        if let audioIn = usage.audioInputTokens, let audioRate = rate.audioInput {
            usd += Double(audioIn) * audioRate
        }
        if let audioOut = usage.audioOutputTokens, let audioRate = rate.audioOutput {
            usd += Double(audioOut) * audioRate
        }
        return usd / 1_000_000
    }

    static func formatTokenCount(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
    }

    /// Four decimals below a cent so small per-answer costs don't round to "$0.00".
    static func formatUSD(_ value: Double) -> String {
        value >= 0.01 ? String(format: "%.2f", value) : String(format: "%.4f", value)
    }
}
