namespace Components
{
    // Base class for Unity-style components.
    //
    // Concrete impl is the hand-written Lua under runtime/Component.luau —
    // this C# stub exists so user code typechecks and gets IntelliSense.
    // Method bodies return default and never run; the transformer rewrites
    // call sites to dispatch into the Lua runtime.
    //
    // Usage:
    //
    //   public class Health : Component
    //   {
    //       [SerializedField] private int max = 100;
    //       [SerializedField] private int current = 100;
    //
    //       protected override void Awake()
    //       {
    //           // Instance is the Roblox Instance this component is
    //           // attached to. Set by the runtime before Awake fires.
    //       }
    //
    //       protected override void Update(float dt)
    //       {
    //           if (current <= 0) Instance.Destroy();
    //       }
    //   }
    //
    // Lifecycle methods are virtual no-ops; the transformer scans for
    // overrides and only emits Lua bindings for the methods you actually
    // override, so empty overrides cost nothing at runtime.
    public abstract class Component
    {
        // The Roblox Instance this component instance is attached to.
        // Assigned by the runtime via Component.spawn before Awake runs;
        // safe to read in every lifecycle hook.
        public Instance Instance { get; }

        // Returns the same-Instance component of the requested type, or
        // null if none is attached. Use this when the dependency is
        // optional — e.g. "tint the part if it has a Highlight component".
        public T GetComponent<T>() where T : Component => default;

        // Same lookup, but throws when the component is missing. Use
        // when the dependency is mandatory — e.g. DamageOnTouch
        // requiring Health. The thrown error includes the missing type
        // and the Instance path so debugging is straightforward.
        public T GetRequiredComponent<T>() where T : Component => default;

        // Try-pattern variant for the cases where the consuming code
        // branches on presence without needing a separate null check.
        public bool TryGetComponent<T>(out T component) where T : Component
        {
            component = default;
            return default;
        }

        // ----------------------------------------------------------------
        // Lifecycle — override to opt in. Default bodies are empty so the
        // transformer can detect "did the user override?" by checking the
        // declaring type at code-gen time. An override that's empty still
        // gets emitted (the transformer can't tell intent from body); if
        // you don't need the hook, don't override it.
        // ----------------------------------------------------------------

        // Called once when the component is attached to its Instance,
        // before any sibling component's Start. Other components on the
        // same Instance may not yet be Awake — don't reach across them
        // here; do that in Start instead.
        protected virtual void Awake() { }

        // Called once after every Awake on the Instance has run. Safe
        // place to call GetComponent — sibling components are guaranteed
        // to exist and to have completed their own Awake.
        protected virtual void Start() { }

        // Called every Heartbeat (post-physics). Runs on whichever side
        // (server / client) the Instance lives on. The Lua runtime wraps
        // this in pcall so a throw from one component doesn't kill the
        // tick for the rest.
        protected virtual void Update(float dt) { }

        // Called every RenderStepped (pre-render), client only. Components
        // attached on the server never see this fire — document and move
        // on; the runtime makes no attempt to emulate it server-side.
        protected virtual void LateUpdate(float dt) { }

        // Called when the component is detached (tag removed, Instance
        // destroyed, or the runtime is shutting down). The Instance may
        // already be partially torn down — read Instance.Parent etc. with
        // that in mind.
        protected virtual void OnDestroy() { }
    }
}
