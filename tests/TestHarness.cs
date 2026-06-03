using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp;
using RobloxCSharp.Common.Diagnostics;
using RobloxCSharp.Plugins;
using RobloxCSharp.Transformer;
using RobloxCSharp.Transformer.Extensibility;

namespace Components.Tests
{
	internal static class TestHarness
	{
		public const string Stubs = @"
using System;

namespace RobloxCSharp.RobloxApi
{
	public class Instance { }
}

namespace Components
{
	public abstract class Component
	{
		public RobloxCSharp.RobloxApi.Instance Instance { get; }
		protected virtual void Awake() { }
	}

	public class ComponentsService
	{
		public ComponentsService(DependencyInjection.Container container) { }
		public void Register<T>() where T : Component { }
	}

	[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
	public sealed class SerializedFieldAttribute : Attribute { }
}

namespace DependencyInjection
{
	public class Container { }
	public abstract class Installer
	{
		protected Container Container { get; }
		public Installer(Container container) { Container = container; }
		public abstract void InstallBindings();
	}
}

[AttributeUsage(AttributeTargets.Class)]
public class ServerAttribute : Attribute { }

[AttributeUsage(AttributeTargets.Class)]
public class ClientAttribute : Attribute { }
";

		public static (TransformerState State, CompilationUnitSyntax Root, CSharpCompilation Compilation) Compile(string userSource)
		{
			SyntaxTree userTree = CSharpSyntaxTree.ParseText(userSource);
			SyntaxTree stubsTree = CSharpSyntaxTree.ParseText(Stubs);
			CSharpCompilation compilation = CompilationFactory.Create("Anonymous", userTree, stubsTree);
			CSharpCompilationContext context = new(userTree, compilation);
			TransformerState state = new(context);
			return (state, (CompilationUnitSyntax)userTree.GetRoot(), compilation);
		}

		public static void OnCompile(IRobloxCSharpExtension ext, CSharpCompilation compilation)
		{
			ext.OnCompile(compilation, Array.Empty<Plugin>(), new DiagnosticBag());
		}

		public static T FirstNode<T>(CompilationUnitSyntax root) where T : SyntaxNode
		{
			foreach (SyntaxNode node in root.DescendantNodes())
			{
				if (node is T t) return t;
			}
			throw new InvalidOperationException($"No {typeof(T).Name} found.");
		}
	}
}
