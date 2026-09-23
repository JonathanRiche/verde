//! Exact UI role tables for Verde's own themes, read from the Omarchy theme
//! folders in examples/omarchy so the downloadable packages match what the
//! desktop app ships. Imported only by the /themes route so the TOML stays
//! out of the client bundle.

import verdeDarkToml from '../../../../examples/omarchy/verde-dark/colors.toml?raw'
import verdeLegacyToml from '../../../../examples/omarchy/verde-legacy/colors.toml?raw'
import verdeLightToml from '../../../../examples/omarchy/verde-light/colors.toml?raw'
import { verdeRoleTable } from './theme-package'

const ROLE_TABLES: Record<string, Record<string, string>> = {
  verde: verdeRoleTable(verdeLegacyToml),
  'verde-dark': verdeRoleTable(verdeDarkToml),
  'verde-light': verdeRoleTable(verdeLightToml),
}

export function verdeThemeRoles(slug: string): Record<string, string> {
  return ROLE_TABLES[slug] ?? {}
}
