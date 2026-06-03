using DependencyInjection;

namespace Components
{
    /// <summary>
    /// Runtime service that owns the DI container and wires
    /// <c>CollectionService</c> watchers per registered component type.
    /// The compiler auto-registers every <see cref="Component"/> subclass
    /// against your project's <c>Installer</c>; you rarely call
    /// <see cref="Register{T}"/> by hand.
    /// </summary>
    public class ComponentsService
    {
        public ComponentsService(Container container) { }

        /// <summary>
        /// Watches <c>Component:&lt;T&gt;</c> tags and spawns / destroys an
        /// instance of <typeparamref name="T"/> as tags appear and disappear.
        /// </summary>
        public void Register<T>() where T : Component { }
    }
}
