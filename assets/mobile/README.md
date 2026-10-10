# Mobile theme presets

`themes.json` is the shared, offline palette catalog bundled by the Android and
iOS apps. Its eight presets come from `packages/website/src/lib/site-theme.ts`
and use the semantic colors exported by `portableThemePackage` in
`packages/website/src/lib/theme-package.ts`.

Included: Tokyo Night, Catppuccin, Catppuccin Latte, Gruvbox, Kanagawa, Matte Black,
Osaka Jade, and Ristretto. Verde Legacy and Mist Deep are intentionally excluded.
System, Light, and Dark remain native choices; System follows phone appearance.
Catppuccin Latte uses light system controls; the other presets use dark controls.

When updating a website preset, regenerate its semantic color map with
`portableThemePackage` and update this asset so both mobile apps stay identical.
