# roblox-csharp-components

Unity-style component system for [roblox-csharp](https://github.com/Stiexeno/roblox-csharp): write `Health : Component` in C#, tag an Instance with `Component:Health`, and the runtime spawns it with DI-resolved constructor dependencies.

## Install

```sh
roblox-csharp plugin add Stiexeno/roblox-csharp-components
```

Requires the [DependencyInjection](https://github.com/Stiexeno/roblox-csharp-dependency-injection) plugin — auto-registration is emitted as a tail on your project's `Installer`, so a `[Server]`/`[Client]` Installer subclass must exist or components silently never register.

## Usage

```csharp
using Components;

public class Health : Component
{
    [SerializedField] private int max = 100;
    [SerializedField] private BasePart hitbox;       // Instance ref (GUID-backed)
    [SerializedField] private Vector3 offset;        // Vector3 / Color3 attributes
    [SerializedField] private Shield shield;         // Component ref (resolved live)
    [SerializedField] private MoveState state;       // enum (stored as int)
    [SerializedField] private KnockbackInfo knock;   // plain class → composite (flattened leaves)
    [SerializedField] private List<int> thresholds;  // list / array

    public Health(IGameEvents events) { }  // resolved from your installer's container

    protected override void Awake() { }            // on spawn; Instance is set
    protected override void Start() { }            // next frame after every sibling's Awake
    protected override void Update(float dt) { }   // Heartbeat, server + client
    protected override void LateUpdate(float dt) { } // RenderStepped, client only
    protected override void OnDestroy() { }        // tag removed / Instance destroyed
}
```

No Register call, no installer boilerplate. Tag via Studio's Tag Editor, the inspector below, or `CollectionService:AddTag`.

Tagged instances under `ServerStorage` / `ReplicatedStorage` are treated as templates and never spawn; a clone (or reparent) into the live DataModel spawns normally.

### Context

Components register into the DI installer matching their own module's Rojo context: server components into the `[Server]` installer, client components into the `[Client]` one. Shared components (ReplicatedStorage modules) register **server-side only** — registering both sides would double-spawn every Workspace instance; put the source in a client context if you want client behavior. A component that matches no installer (or a project with no installer at all) gets an RC0021 warning at compile time.

### Sibling lookup

```csharp
var hitbox = GetComponent<Hitbox>();          // sibling on the same Instance, or null
var health = GetRequiredComponent<Health>();  // errors with a clear message if missing
var maybe  = TryGetComponent<Shield>();       // same as GetComponent; returns null when absent
```

Safe from `Start` onward (`Awake` order between siblings is undefined). `TryGetComponent` returns `T` rather than Unity's `bool` + `out` shape — out-params don't lower to Luau.

## SerializedField

Persisted as Instance Attributes named `<ComponentName>_<Member>`; two-way bound (attribute edits propagate into the live component, code assignments push back). Works on fields and settable auto-properties.

Supported: `int` / `long` / `float` / `double` / `string` / `bool`, `Vector3` / `Color3` (stored as native attributes), enums, `Instance` subclasses (stored as a `_uid` GUID attribute, resolved via the runtime registry), `Component` subclasses (stored as the target Instance's GUID, resolved to the live component on each read — so spawn order doesn't matter), plain classes of the above (flattened composites, cycles rejected), and `List<T>` / `T[]` of any of those (stored as `<prefix>_Count` + `<prefix>_1..N`).

## Studio inspector

`studio-plugin/ComponentEditor.server.luau` — save as a local plugin (drop in `ServerStorage`, right-click → **Save as Local Plugin**). Discovers compiled component definitions by scanning ReplicatedStorage / ServerScriptService / StarterPlayerScripts. Provides:

- Add / remove components on the selected Instance (attributes initialized / cleaned up)
- Typed editors: number, string, bool, enum dropdown with search, Instance picker (pick-from-selection + clear), composite foldouts, list add/remove/reorder-on-delete
- Custom property drawers: a ModuleScript returning `{ DrawerFor = "enum:MoveState", Draw = function(...) end }` overrides built-ins
- Every edit is a `ChangeHistoryService` recording — Ctrl+Z works
- Auto-refreshes when a component ModuleScript's Source changes or scripts are added/removed under the discovery roots — recompiling after a `[SerializedField]` edit updates the panel without re-selecting

## Caveats

- List fields read live from attributes, but list *mutations in code* are runtime-only — persist via the inspector or by writing the attributes yourself. Assigning to a list nested inside a composite is unsupported. Nested lists (`List<List<T>>`) are unsupported.
- Instance refs resolve from Workspace and ReplicatedStorage only.
- Tag edits made outside the inspector don't refresh it until the selection changes.

## License

MIT.
