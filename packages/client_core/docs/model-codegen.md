# Native wire models (K-15)

`src/model_registry.zig` is the **single export registry**. The build step
reflects these Zig types at comptime (`@typeInfo`), including nested structs,
enums, optional fields, slices and tagged unions. It writes committed models to:

- `packages/mobile_android/app/src/main/java/dev/verdeai/core/CoreModels.kt`
  (`dev.verdeai.core`, kotlinx.serialization).
- `packages/mobile_ios/App/CoreModels.swift` (Foundation Codable).

Run from the repository root:

```sh
mise run mobile-models-generate
mise run mobile-models-check
```

The second task compares bytes without modifying source files, and fails for
missing or stale output. `.github/workflows/mobile-models.yml` runs the same
`zig build models-check --release=safe` step on master pushes and PRs, including changes to shared dependency types.
It is a dedicated task, not a dependency of `mobile-core-test`.
Generation has no timestamps, filesystem traversal or external formatter.
Both generated files must be committed with their Zig source changes.

## Adding a type

1. Define a public Zig **wire** struct, enum or tagged union in the owning
   module. Keep internal state, allocators and callbacks out of it. K-06's
   previously inline shapes have names in `src/wire.zig`; its config/error
   aliases refer directly to the existing host types. K-07/K-08/K-11 can keep
   their new types in their own modules.
2. Import the module in `src/model_registry.zig`, then append
   `.{ "NativeName", module.Type }` to `types`. The string is the stable Kotlin
   and Swift type name. Register shared or recursive nested types too; references
   resolve to that registered name. Unregistered nested types are emitted under
   `Parent` + PascalCase field name. Keep those names unique. Recursive types
   must be registered, and Swift recursion must pass through a collection or
   another indirect representation.
3. For a new event/effect, append its payload struct to `wire.Event` or
   `wire.Effect`; the union tag is its exact JSON `type`. Include the common
   event/effect envelope fields in that payload. The registry already exports
   these unions, so their new variants need no additional registry entry.
4. Run generation, the staleness check, `mobile-core-test`, and both platform
   builds. Add boundary/codec fixtures when introducing a new wire shape.
   Never hand-edit generated files or create a separate platform schema list.

Supported scalar mappings: `bool`; fixed-width integers (Kotlin uses `Int`
through 16 bits, `Long` through signed 64 bits/u32, and `ULong` for u64;
Swift preserves signedness/width); f32/f64; UTF-8 `[]const u8` → String.
Other slices become lists/arrays. Optionals preserve nullable values. Zig
field defaults become native defaults. Unsupported shapes/defaults fail the
build at comptime rather than silently producing an incorrect codec. Arrays,
opaque pointers, custom JSON serializers and engine-only unions are not wire
models; give them an explicit wire representation first.

Local revisions, generations, offsets and sequences stay **strings** in Zig
and both native languages. No floating-point conversion is involved. The
constructor's numeric `jitter_seed` supports all u64 values. `std.json.Value`
becomes Kotlin `JsonElement` or Swift `JSONValue`, preserving integer precision.
It is used only for opaque log fields and K-06's empty, not-yet-implemented
collections. K-09 must replace those collection items with its typed view models;
K-15 does not implement the future projection engines.

## D-02 / I-02 consumption

Kotlin must use `CoreJson` (unknown fields ignored, defaults and explicit nulls
encoded). Encode events **as the sealed base type** so kotlinx.serialization
includes the flat discriminator:

```kotlin
val event: Event = EventStart(now_ms = now, wall_time_ms = wall,
    foreground = true, network_available = true)
val bytes = CoreJson.encodeToString<Event>(event).encodeToByteArray()
val batch = CoreJson.decodeFromString<EffectBatch>(reply.decodeToString())
```

Import `kotlinx.serialization.encodeToString` / `decodeFromString` for these
extensions. `Effect` subclasses are named `EffectSecureStoreGet`, etc.
There is no additional `payload` object. Do not encode concrete event subclasses
without the base serializer, or replace `CoreJson` with default `Json` settings.

Swift uses ordinary `JSONEncoder` / `JSONDecoder`, with default key strategies:

```swift
let event = Event.start(EventStart(now_ms: now, wall_time_ms: wall,
    foreground: true, network_available: true))
let bytes = try JSONEncoder().encode(event)
let batch = try JSONDecoder().decode(EffectBatch.self, from: reply)
```

Swift enum cases carry generated payload structs. They dispatch on the same
flat `type` key, and payload encoders include that key even when used directly.
Generated encoders explicitly write nil fields as JSON null. Unknown object
fields are ignored; unknown event/effect tags throw, so an executor cannot
silently drop an unrecognized effect. Enum values use their exact wire spelling.
Wire validation (revision support, bounds, correlations and lifecycle) remains
owned by the core. Native models do not authorize or execute effects.

`HostsQuery`, `HomeQuery` and `WorkspacesQuery` are typed query envelopes. Later
query owners can register `wire.Query(their.View)` under another stable name.
The unknown-selector error envelope decodes with `data == null`.

## Verification

The Zig contract test decodes real K-06 query/effect output through the exported
shapes. Android and Swift codec tests cover tags, defaults, explicit nulls,
unknown fields, unknown tags and wide integer values. Run with
`mise run mobile-android-test` / `mise run mobile-ios-test` (Mac).
The generator's only app build integration is Kotlin's serialization plugin and
runtime; XcodeGen already includes Swift files under `App`.
