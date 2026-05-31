using DependencyInjection;

namespace Components
{
    // Runtime side of the Components plugin — owns the CollectionService
    // tag watchers and the DI-driven spawn pipeline.
    //
    // Users never construct, bind, or call this service themselves. The
    // compiler emits a binding + Register<T>() call per discovered
    // Component subclass in the installer's auto-boot tail (see
    // CompilationUnitTransformer.EmitInstallerBootTail), so all the user
    // does is:
    //
    //   1. Write a `Health : Component` class.
    //   2. In Studio, tag an Instance with "Component:Health" via the
    //      Components editor.
    //   3. Spawn the Instance — the runtime takes it from there.
    //
    // No explicit registration. No installer noise. The whole rig
    // disappears into the build pipeline.
    public class ComponentsService
    {
        // Container injected so the service can resolve each registered
        // component's __ctorParams at spawn time. Lifetime is one-per-
        // container, bound AsSingle by the compiler-emitted tail.
        public ComponentsService(Container container) { }

        // Wires a CollectionService watcher for "Component:<T>". On
        // every tag match (existing or future), the service:
        //   1. Calls Component.spawn(definition, instance) to build the
        //      self table with metatable + attribute wiring.
        //   2. Resolves T's __ctorParams via the injected container.
        //   3. Invokes :constructor with the resolved deps (if T declared
        //      one).
        //   4. Fires Awake immediately, defers Start to the next frame so
        //      sibling components are guaranteed up first.
        //
        // Idempotent — registering the same T twice is a no-op. The
        // generic parameter survives transpile via [Reified]-equivalent
        // lowering, so the runtime receives the definition table itself
        // rather than a stringly name.
        public void Register<T>() where T : Component { }
    }
}
