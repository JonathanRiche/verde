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
  /// Cursor only; Codex supports Fast for every model.
  fast_supported?: boolean
}

/// One row of the daemon's provider.models.list result (harness ModelInfo).
export interface DynamicModelRow {
  provider_id?: string
  model_id: string
  model_name?: string
  reasoning_supported?: boolean
  reasoning_variant_keys?: string[] | null
  claude_effort_values?: string[] | null
  cursor_fast_supported?: boolean
  cursor_reasoning_values?: string[] | null
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
    } else if (provider === 'cursor') {
      options.push({
        label,
        value: row.model_id,
        ...(row.cursor_reasoning_values?.length ? { variants: row.cursor_reasoning_values } : {}),
        ...(row.cursor_fast_supported ? { fast_supported: true } : {}),
      })
    } else if (provider === 'pi') {
      // Pi model refs are "<provider_id>/<model_id>" strings passed to
      // `pi --model`; thinking levels map 1:1 onto Verde effort tags.
      options.push({
        label,
        value: row.model_id,
        ...(row.reasoning_supported !== false ? { efforts: CLAUDE_FULL_EFFORTS } : {}),
      })
    } else if (provider === 'grok') {
      // Grok Build reports its catalog over ACP; every model accepts a
      // reasoning effort (low..xhigh), and `max` is not offered.
      options.push({ label, value: row.model_id, efforts: GROK_EFFORTS })
    } else if (provider === 'muse') {
      options.push({ label, value: row.model_id, efforts: MUSE_EFFORTS })
    } else {
      options.push({ label, value: row.model_id })
    }
  }
  return options
}

const DEFAULT_EFFORT: EffortOption = { label: 'Default', value: null }

/// CODEX_REASONING_OPTIONS for models through GPT-5.5.
const CODEX_EFFORTS: EffortOption[] = [
  DEFAULT_EFFORT,
  { label: 'Low', value: 'low' },
  { label: 'Medium', value: 'medium' },
  { label: 'High', value: 'high' },
  { label: 'Xhigh', value: 'xhigh' },
]

/// GPT-5.6 adds max reasoning effort across Sol, Terra, and Luna.
const CODEX_56_EFFORTS: EffortOption[] = [
  ...CODEX_EFFORTS,
  { label: 'Max', value: 'max' },
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
  { label: 'GPT-5.6 Sol', value: 'gpt-5.6-sol', efforts: CODEX_56_EFFORTS },
  { label: 'GPT-5.5', value: 'gpt-5.5', efforts: CODEX_EFFORTS },
  { label: 'GPT-5.6 Terra', value: 'gpt-5.6-terra', efforts: CODEX_56_EFFORTS },
  { label: 'GPT-5.6 Luna', value: 'gpt-5.6-luna', efforts: CODEX_56_EFFORTS },
  { label: 'GPT-5.3 Codex Spark', value: 'gpt-5.3-codex-spark', efforts: CODEX_EFFORTS },
]

const CLAUDE_MODELS: ModelOption[] = [
  { label: 'Fable 5.1', value: 'fable[1m]', efforts: CLAUDE_FULL_EFFORTS },
  { label: 'Default (Opus 5)', value: 'default', efforts: CLAUDE_FULL_EFFORTS },
  { label: 'Opus 5 (1M context)', value: 'opus[1m]', efforts: CLAUDE_FULL_EFFORTS },
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

/// Pi's static fallback mirrors PI_MODEL_OPTIONS: "default" defers to the
/// model configured in the user's pi settings.
const PI_MODELS: ModelOption[] = [
  { label: 'Default (pi config)', value: 'default', efforts: CLAUDE_FULL_EFFORTS },
]

/// Mirror of the desktop FX_MODEL_OPTIONS fallback; fx ACP exposes no
/// effort control today, so no efforts are offered.
const FX_MODELS: ModelOption[] = [
  { label: 'Default (fx config)', value: 'default' },
  { label: 'GPT-5.2', value: 'openai/gpt-5.2' },
  { label: 'GPT-5.4 Mini', value: 'openai/gpt-5.4-mini' },
  { label: 'GPT-5.1 Codex', value: 'openai/gpt-5.1-codex' },
  { label: 'Claude Sonnet 5', value: 'anthropic/claude-sonnet-5' },
]

/// GROK_REASONING_OPTIONS: grok efforts stop at xhigh.
const GROK_EFFORTS: EffortOption[] = [
  DEFAULT_EFFORT,
  { label: 'Low', value: 'low' },
  { label: 'Medium', value: 'medium' },
  { label: 'High', value: 'high' },
  { label: 'Extra high', value: 'xhigh' },
]

/// Grok's static fallback mirrors GROK_MODEL_OPTIONS: "default" defers to the
/// model persisted in the user's grok config.
const GROK_MODELS: ModelOption[] = [
  { label: 'Default (grok config)', value: 'default', efforts: GROK_EFFORTS },
  { label: 'Grok 4.6', value: 'grok-4.6', efforts: GROK_EFFORTS },
  { label: 'Grok 4.5', value: 'grok-4.5', efforts: GROK_EFFORTS },
]

/// Muse's MSP tier `ultra` is persisted as Verde's existing `max` value; the
/// native transport converts it back to `ultra` on turn/start.
const MUSE_EFFORTS: EffortOption[] = [
  DEFAULT_EFFORT,
  { label: 'Low', value: 'low' },
  { label: 'Medium', value: 'medium' },
  { label: 'High', value: 'high' },
  { label: 'Xhigh', value: 'xhigh' },
  { label: 'Ultra', value: 'max' },
]

const MUSE_MODELS: ModelOption[] = [
  { label: 'Default (Muse config)', value: 'default', efforts: MUSE_EFFORTS },
  { label: 'Muse Spark 1.3 Contributor', value: 'muse-spark-1.3-contributor', efforts: MUSE_EFFORTS },
]

const CURSOR_GROK_VARIANTS = ['low', 'medium', 'high']
const CURSOR_GPT_FULL_VARIANTS = ['none', 'low', 'medium', 'high', 'xhigh', 'max']
const CURSOR_GPT_55_VARIANTS = ['none', 'low', 'medium', 'high', 'extra-high']
const CURSOR_GPT_54_VARIANTS = ['low', 'medium', 'high', 'xhigh']
const CURSOR_CLAUDE_VARIANTS = ['low', 'medium', 'high', 'xhigh', 'max']

/// Cursor reasoning is stored as a provider variant; Fast is exposed only on
/// the same model rows marked cursor_fast_supported by the desktop.
const CURSOR_MODELS: ModelOption[] = [
  { label: 'Auto', value: 'auto' },
  { label: 'Composer 2.5', value: 'composer-2.5', fast_supported: true },
  { label: 'Cursor Grok 4.5', value: 'cursor-grok-4.5-high', variants: CURSOR_GROK_VARIANTS, fast_supported: true },
  { label: 'Opus 4.8 Thinking', value: 'claude-opus-4-8-thinking-high', variants: CURSOR_CLAUDE_VARIANTS, fast_supported: true },
  { label: 'GPT-5.6 Sol', value: 'gpt-5.6-sol-medium', variants: CURSOR_GPT_FULL_VARIANTS, fast_supported: true },
  { label: 'GPT-5.5', value: 'gpt-5.5-medium', variants: CURSOR_GPT_55_VARIANTS, fast_supported: true },
  { label: 'Fable 5 Thinking', value: 'claude-fable-5-thinking-high', variants: CURSOR_CLAUDE_VARIANTS },
  { label: 'Sonnet 5 Thinking', value: 'claude-sonnet-5-thinking-high', variants: CURSOR_CLAUDE_VARIANTS },
  { label: 'GPT-5.6 Terra', value: 'gpt-5.6-terra-medium', variants: CURSOR_GPT_FULL_VARIANTS, fast_supported: true },
  { label: 'GPT-5.6 Luna', value: 'gpt-5.6-luna-medium', variants: CURSOR_GPT_FULL_VARIANTS, fast_supported: true },
  { label: 'GPT-5.4', value: 'gpt-5.4-medium', variants: CURSOR_GPT_54_VARIANTS, fast_supported: true },
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
    case 'pi':
      return PI_MODELS
    case 'fx':
      return FX_MODELS
    case 'grok':
      return GROK_MODELS
    case 'muse':
      return MUSE_MODELS
    default:
      return []
  }
}

export function modelSupportsFast(provider: string | null | undefined, option: ModelOption | undefined): boolean {
  return provider === 'codex' || (provider === 'cursor' && option?.fast_supported === true)
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
