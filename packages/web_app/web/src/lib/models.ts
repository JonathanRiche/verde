/// Static provider model/reasoning pickers for the web composer.
///
/// Mirrors the desktop tables in packages/desktop/src/state/provider_models.zig
/// (OPENCODE/CODEX/CURSOR/CLAUDE_MODEL_OPTIONS + effort values). The desktop
/// augments these with dynamic OpenCode/Cursor/Claude metadata fetched through
/// provider bridges; the detached web client only has the daemon store, so it
/// ships the same static fallback lists. Keep them in sync when the desktop
/// tables change.

export interface EffortOption {
  label: string
  /// Null selects the provider default (no reasoning_effort stored).
  value: string | null
}

export interface ModelOption {
  label: string
  value: string
  /// Effort menu for this model; undefined hides the effort picker.
  efforts?: EffortOption[]
  /// OpenCode reasoning variant keys; undefined hides the variant picker.
  variants?: string[]
}

/// One row of the daemon's provider.models.list result (harness ModelInfo).
export interface DynamicModelRow {
  provider_id?: string
  model_id: string
  model_name?: string
  reasoning_supported?: boolean
  reasoning_variant_keys?: string[] | null
  claude_effort_values?: string[] | null
}

/// Convert a daemon catalog into picker options, mirroring how the desktop
/// populates its dynamic option lists per provider.
export function dynamicModelOptions(provider: string, rows: DynamicModelRow[]): ModelOption[] {
  const options: ModelOption[] = []
  for (const row of rows) {
    if (!row.model_id) continue
    const label = row.model_name || row.model_id
    if (provider === 'opencode') {
      // OpenCode model refs are "<provider_id>/<model_id>" like the static table.
      const value = row.provider_id ? `${row.provider_id}/${row.model_id}` : row.model_id
      options.push({
        label,
        value,
        ...(row.reasoning_variant_keys?.length ? { variants: row.reasoning_variant_keys } : {}),
      })
    } else if (provider === 'claude') {
      const effort_values = row.claude_effort_values?.length
        ? row.claude_effort_values
        : row.reasoning_supported !== false
          ? ['low', 'medium', 'high']
          : []
      options.push({
        label,
        value: row.model_id,
        ...(effort_values.length
          ? {
              efforts: [
                DEFAULT_EFFORT,
                ...effort_values.map((value) => ({ label: effortLabel(value), value })),
              ],
            }
          : {}),
      })
    } else {
      options.push({ label, value: row.model_id })
    }
  }
  return options
}

const DEFAULT_EFFORT: EffortOption = { label: 'Default', value: null }

/// CODEX_REASONING_OPTIONS: shared across all Codex models.
const CODEX_EFFORTS: EffortOption[] = [
  DEFAULT_EFFORT,
  { label: 'Low', value: 'low' },
  { label: 'Medium', value: 'medium' },
  { label: 'High', value: 'high' },
  { label: 'Xhigh', value: 'xhigh' },
]

/// CLAUDE_FULL_EFFORT_VALUES for reasoning-capable Claude models.
const CLAUDE_FULL_EFFORTS: EffortOption[] = [
  DEFAULT_EFFORT,
  { label: 'Low', value: 'low' },
  { label: 'Medium', value: 'medium' },
  { label: 'High', value: 'high' },
  { label: 'Xhigh', value: 'xhigh' },
  { label: 'Max', value: 'max' },
]

const CODEX_MODELS: ModelOption[] = [
  { label: 'GPT-5.6 Sol', value: 'gpt-5.6-sol', efforts: CODEX_EFFORTS },
  { label: 'GPT-5.5', value: 'gpt-5.5', efforts: CODEX_EFFORTS },
  { label: 'GPT-5.6 Terra', value: 'gpt-5.6-terra', efforts: CODEX_EFFORTS },
  { label: 'GPT-5.6 Luna', value: 'gpt-5.6-luna', efforts: CODEX_EFFORTS },
  { label: 'GPT-5.3 Codex Spark', value: 'gpt-5.3-codex-spark', efforts: CODEX_EFFORTS },
]

const CLAUDE_MODELS: ModelOption[] = [
  { label: 'Default (Opus 5)', value: 'default', efforts: CLAUDE_FULL_EFFORTS },
  { label: 'Opus 5 (1M context)', value: 'opus[1m]', efforts: CLAUDE_FULL_EFFORTS },
  { label: 'Fable', value: 'claude-fable-5[1m]', efforts: CLAUDE_FULL_EFFORTS },
  { label: 'Sonnet 5', value: 'sonnet', efforts: CLAUDE_FULL_EFFORTS },
  { label: 'Haiku 4.5', value: 'haiku' },
]

/// OpenCode reasoning variants are dynamic model metadata the desktop fetches
/// live; the static table has none, so the web picker offers models only.
const OPENCODE_MODELS: ModelOption[] = [
  { label: 'GPT-5.5', value: 'opencode/gpt-5.5' },
  { label: 'GPT-5.4', value: 'opencode/gpt-5.4' },
  { label: 'Claude Opus 4.7', value: 'opencode/claude-opus-4-7' },
  { label: 'Claude Opus 4.6', value: 'opencode/claude-opus-4-6' },
  { label: 'Claude Sonnet 4.5', value: 'opencode/claude-sonnet-4-5' },
  { label: 'Gemini 3.1 Pro', value: 'opencode/gemini-3.1-pro' },
]

/// Cursor encodes effort in the model id and applies it through provider
/// params, not thread reasoning_effort, so the web picker offers models only.
const CURSOR_MODELS: ModelOption[] = [
  { label: 'Auto', value: 'auto' },
  { label: 'Composer 2.5', value: 'composer-2.5' },
  { label: 'Cursor Grok 4.5', value: 'cursor-grok-4.5-high' },
  { label: 'Opus 4.8 Thinking', value: 'claude-opus-4-8-thinking-high' },
  { label: 'GPT-5.6 Sol', value: 'gpt-5.6-sol-medium' },
  { label: 'GPT-5.5', value: 'gpt-5.5-medium' },
  { label: 'Fable 5 Thinking', value: 'claude-fable-5-thinking-high' },
  { label: 'Sonnet 5 Thinking', value: 'claude-sonnet-5-thinking-high' },
  { label: 'GPT-5.6 Terra', value: 'gpt-5.6-terra-medium' },
  { label: 'GPT-5.6 Luna', value: 'gpt-5.6-luna-medium' },
  { label: 'GPT-5.4', value: 'gpt-5.4-medium' },
  { label: 'Gemini 3.1 Pro', value: 'gemini-3.1-pro' },
  { label: 'Gemini 3.5 Flash', value: 'gemini-3.5-flash' },
  { label: 'Kimi K3', value: 'kimi-k3' },
  { label: 'GLM 5.2', value: 'glm-5.2-high' },
]

export function modelOptionsFor(provider: string | null | undefined): ModelOption[] {
  switch (provider) {
    case 'codex':
      return CODEX_MODELS
    case 'claude':
      return CLAUDE_MODELS
    case 'opencode':
      return OPENCODE_MODELS
    case 'cursor':
      return CURSOR_MODELS
    default:
      return []
  }
}

/// Effort menu for the current model within an option list; empty hides the chip.
export function effortOptionsIn(
  options: ModelOption[],
  model: string | null | undefined,
): EffortOption[] {
  if (options.length === 0) return []
  const selected = options.find((option) => option.value === model) ?? options[0]
  return selected.efforts ?? []
}

/// OpenCode variant keys for the current model; empty hides the variant chip.
export function variantOptionsIn(options: ModelOption[], model: string | null | undefined): string[] {
  if (options.length === 0) return []
  const selected = options.find((option) => option.value === model) ?? options[0]
  return selected.variants ?? []
}

/// Effort menu against the static tables (fallback when no daemon catalog).
export function effortOptionsFor(
  provider: string | null | undefined,
  model: string | null | undefined,
): EffortOption[] {
  return effortOptionsIn(modelOptionsFor(provider), model)
}

export function effortLabel(value: string | null | undefined): string {
  if (!value) return 'Default'
  const known = CLAUDE_FULL_EFFORTS.find((option) => option.value === value)
  return known?.label ?? value
}
