# roblox-csharp-components

Unity-style component system for [roblox-csharp](https://github.com/Stiexeno/roblox-csharp). Write `Health : Component` in C#, tag a Roblox Instance, and the runtime spawns the component with DI-resolved dependencies — no manual registration, no boilerplate in your installer.

## Install

Requires the [DependencyInjection](https://github.com/Stiexeno/roblox-csharp-dependency-injection) plugin (every project that uses Components has an Installer; the auto-registration tail relies on it).

```sh
roblox-csharp plugin add Stiexeno/roblox-csharp-components
```

That clones into `plugins/Components/`. The compiler picks it up automatically on the next build.

## Quick start

### 1. Write a component

```csharp
using Components;

public class Health : Component
{
    [SerializedField] private int max = 100;
    [SerializedField] private int current = 100;

    protected override void Awake()
    {
        // Runs once when the component attaches to its Instance.
        // self.Instance is the Roblox Instance.
    }

    protected override void Update(float dt)
    {
        if (current <= 0) Instance.Destroy();
    }

    public void TakeDamage(int amount)
    {
        current = Math.Max(0, current - amount);
    }
}
```

That's the whole authoring surface. No `[Component]` attribute. No Register call. No binding in the installer.

### 2. Tag a Roblox Instance

Add the tag `Component:Health` to any Instance via Studio's Tag Editor (or `CollectionService:AddTag(part, "Component:Health")`). The compiler-generated installer tail registers the watcher; the runtime spawns a `Health` instance the moment the tag appears.

### 3. (Optional) DI-injected dependencies

Components are constructed by the DI container, so constructor parameters get resolved automatically:

```csharp
public class DamageOnTouch : Component
{
    private readonly IGameEvents events;

    public DamageOnTouch(IGameEvents events)
    {
        this.events = events;
    }

    protected override void Awake()
    {
        Instance.Touched.Connect(other => events.Fire("Touched", other));
    }
}
```

`IGameEvents` is resolved from whatever your `GameInstaller` bound it to — same as any other DI-resolved class in the project.

## Lifecycle

| Method | Cadence | Side |
|---|---|---|
| `Awake()` | once, on spawn | both |
| `Start()` | once, deferred to next frame after Awake | both |
| `Update(float dt)` | every Heartbeat | both |
| `LateUpdate(float dt)` | every RenderStepped | client only |
| `OnDestroy()` | once, on tag removal | both |

`Awake` runs before any sibling component's `Start`, so cross-component lookup is safe in `Start` but not `Awake`.

## SerializedField

Fields and auto-properties marked `[SerializedField]` are persisted as Roblox Instance Attributes under `<ComponentName>_<MemberName>`. They:

- Show up in Studio's Properties panel under Attributes (and in the Components editor — see below).
- Survive save/load.
- Two-way bind: editing the attribute in Studio updates the live value; assigning the field in code pushes back to the attribute.

Supported types in v1: `int`, `long`, `float`, `double`, `string`, `bool`.

## Studio editor

`studio-plugin/ComponentEditor.server.luau` is a Unity-style inspector that lets you add/remove components on a selected Instance and edit their serialized fields. Save it as a local plugin in Studio:

1. Drop the file somewhere Studio can see it (e.g. `ServerStorage`).
2. Right-click → **Save as Local Plugin**.
3. The **Components** toolbar appears in the Plugins tab.

(Currently the editor only lists Lua-authored definitions in `runtime/Definitions/` — the discovery path for compiled C# components is on the roadmap. For now, add the `Component:<Name>` tag manually via Studio's Tag Editor.)

## How it works (under the hood)

1. The roblox-csharp compiler detects `: Component` subclasses by base-type symbol.
2. Each component class compiles to a `Component.define(name)` module instead of the regular Luau class scaffold — same metatable + serialized-field plumbing the runtime expects.
3. The compiler walks every syntax tree when compiling the project's `Installer`, collects every Component subclass, and appends an auto-registration tail to the installer's boot script:

   ```lua
   _container:Bootstrap()
   local _componentsService = ComponentsService.new(_container)
   _componentsService:Register(Health)
   _componentsService:Register(DamageOnTouch)
   ```

4. `ComponentsService` (this plugin's runtime) holds the container, wires `CollectionService` watchers per registered type, resolves each component's `__ctorParams` via the container at spawn time, and drives the `Update` / `LateUpdate` ticks.

The compiler-side hook is hardcoded in `roblox-csharp` for now (`ComponentLowering.cs` + the `CollectComponentClasses` walker in `CompilationUnitTransformer`). It's intended as the reference implementation for a future "transformer plugin" extension API — at which point this plugin extracts that logic too.

## Roadmap

- [ ] Editor discovery of C# component classes (currently scans `runtime/Definitions/` only)
- [ ] Wider `[SerializedField]` type support (Vector3, Color3, Instance reference)
- [ ] `[RequireComponent(typeof(T))]` for declared dependencies
- [ ] `ChangeHistoryService` integration in the editor
- [ ] Multi-Instance editing in the editor

## License

MIT.
