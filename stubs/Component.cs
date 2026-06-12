namespace Components
{
    /// <summary>
    /// Base class for Unity-style components. Subclass, override lifecycle
    /// methods, tag a Roblox Instance with <c>Component:&lt;ClassName&gt;</c>,
    /// and the runtime spawns one per tagged Instance with constructor
    /// dependencies resolved from the DI container.
    /// </summary>
    public abstract class Component
    {
        /// <summary>The Roblox Instance this component is attached to.</summary>
        public Instance Instance { get; }

        /// <summary>Returns the sibling component of type <typeparamref name="T"/> on the same Instance, or <c>default</c> if absent.</summary>
        public T GetComponent<T>() where T : Component => default;

        /// <summary>Returns the sibling component of type <typeparamref name="T"/>; throws if absent.</summary>
        public T GetRequiredComponent<T>() where T : Component => default;

        /// <summary>Nil-safe variant of <see cref="GetRequiredComponent{T}"/> — returns the sibling component or <c>null</c>. (Unity's out-param shape doesn't lower to Luau.)</summary>
        public T TryGetComponent<T>() where T : Component => default;

        /// <summary>Runs once on spawn, before any sibling component's <see cref="Start"/>. <see cref="Instance"/> is set.</summary>
        protected virtual void Awake() { }

        /// <summary>Runs once on the next frame after <see cref="Awake"/>. Cross-component lookup is safe here.</summary>
        protected virtual void Start() { }

        /// <summary>Per-frame tick driven by <c>RunService.Heartbeat</c>.</summary>
        protected virtual void Update(float dt) { }

        /// <summary>Per-frame tick driven by <c>RunService.RenderStepped</c>. Client-only.</summary>
        protected virtual void LateUpdate(float dt) { }

        /// <summary>Runs once when the tag is removed from <see cref="Instance"/> or the Instance is destroyed.</summary>
        protected virtual void OnDestroy() { }
    }
}
