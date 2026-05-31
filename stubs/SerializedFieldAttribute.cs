using System;

namespace Components
{
    // Marks a field or property on a Component subclass as serialized:
    //
    //   • The value is persisted as a Roblox Instance Attribute on the
    //     Component's host Instance, under the name "<ComponentName>_<MemberName>".
    //     That means it survives save/load and shows up in the Studio
    //     Properties panel like any built-in attribute.
    //
    //   • The Components Studio plugin renders an editor row for it under
    //     the component's section, so designers can tweak it from Studio.
    //
    //   • Reads (`max`) and writes (`max = 50`) go through the runtime's
    //     metatable so the live value stays in sync with the attribute —
    //     edits from Studio during play propagate into the running
    //     component, and assignments from code push back to Studio.
    //
    // Works on both fields and auto-properties:
    //
    //   [SerializedField] private int max = 100;
    //   [SerializedField] public int Max { get; set; } = 100;
    //
    // Sealed because there's no behavioural extension point — the
    // transformer only looks at presence. Future facets (range, tooltip,
    // header) get their own attributes alongside this one.
    [AttributeUsage(AttributeTargets.Field | AttributeTargets.Property,
                    Inherited = false,
                    AllowMultiple = false)]
    public sealed class SerializedFieldAttribute : Attribute
    {
    }
}
