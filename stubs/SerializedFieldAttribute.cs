using System;

namespace Components
{
    /// <summary>
    /// Persists a field or auto-property as a Roblox Instance Attribute
    /// (<c>&lt;ComponentName&gt;_&lt;MemberName&gt;</c>). Two-way bound:
    /// edits in Studio's Properties panel push to the live value, and
    /// assignments in code push back to the attribute. Supported types
    /// in v1: <c>int</c>, <c>long</c>, <c>float</c>, <c>double</c>,
    /// <c>string</c>, <c>bool</c>.
    /// </summary>
    [AttributeUsage(AttributeTargets.Field | AttributeTargets.Property,
                    Inherited = false,
                    AllowMultiple = false)]
    public sealed class SerializedFieldAttribute : Attribute
    {
    }
}
