using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Extensions.Components;
using RobloxCSharp.Transformer.AST.Expressions;
using RobloxCSharp.Transformer.Factory;

namespace Components.Tests
{
	public class ComponentsExtensionTests
	{
		private const string InstallerWithComponents = @"
using Components;
using DependencyInjection;

public class Health : Component { }
public class DamageOnTouch : Component { }

[Server]
public class GameInstaller : Installer
{
	public GameInstaller(Container container) : base(container) { }
	public override void InstallBindings() { }
}
";

		[Fact]
		public void TryRewrite_ComponentSubclass_LowersViaComponentLowering()
		{
			(var state, var root, var compilation) = TestHarness.Compile(@"
using Components;
public class Health : Component { }");
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);
			LuaNode result = ext.TryRewrite(cls, state);

			Assert.IsType<LuaClassDeclaration>(result);
		}

		[Fact]
		public void TryRewrite_NonComponent_ReturnsNull()
		{
			(var state, var root, var compilation) = TestHarness.Compile(@"
public class Plain { }");
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);
			LuaNode result = ext.TryRewrite(cls, state);

			Assert.Null(result);
		}

		[Fact]
		public void TryRewrite_NonClassNode_ReturnsNull()
		{
			(var state, var root, var compilation) = TestHarness.Compile(@"
public class T { void M() {} }");
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			MethodDeclarationSyntax method = TestHarness.FirstNode<MethodDeclarationSyntax>(root);
			LuaNode result = ext.TryRewrite(method, state);

			Assert.Null(result);
		}

		[Fact]
		public void ContributeImports_InstallerUnit_YieldsComponentsAndService()
		{
			(var state, var root, var compilation) = TestHarness.Compile(InstallerWithComponents);
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			List<INamedTypeSymbol> imports = ext.ContributeImports(root, state).ToList();

			Assert.Contains(imports, t => t.Name == "Health");
			Assert.Contains(imports, t => t.Name == "DamageOnTouch");
			Assert.Contains(imports, t => t.Name == "ComponentsService");
		}

		[Fact]
		public void ContributeImports_NonInstallerUnit_IsEmpty()
		{
			(var state, var root, var compilation) = TestHarness.Compile(@"
using Components;
public class Health : Component { }
public class Plain { }
");
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			List<INamedTypeSymbol> imports = ext.ContributeImports(root, state).ToList();

			Assert.Empty(imports);
		}

		[Fact]
		public void OnUnitTransformed_InstallerUnit_AppendsRegisterCalls()
		{
			(var state, var root, var compilation) = TestHarness.Compile(InstallerWithComponents);
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			LuaCompilationUnit unit = LuaFactory.CompilationUnit();
			int membersBefore = unit.Members.Count;

			ext.OnUnitTransformed(unit, root, state);

			int added = unit.Members.Count - membersBefore;
			Assert.True(added >= 3, $"Expected at least 3 additions (1 local + 2 Register calls), got {added}");

			int registerCallCount = unit.Members.OfType<LuaExpressionStatement>()
				.Count(es => es.Expression is LuaInvocationExpression inv
					&& inv.Expression is LuaMemberAccessExpression m
					&& m.MemberName == "Register");
			Assert.Equal(2, registerCallCount);
		}

		[Fact]
		public void OnUnitTransformed_NonInstallerUnit_DoesNothing()
		{
			(var state, var root, var compilation) = TestHarness.Compile(@"
using Components;
public class Health : Component { }
");
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			LuaCompilationUnit unit = LuaFactory.CompilationUnit();
			int membersBefore = unit.Members.Count;

			ext.OnUnitTransformed(unit, root, state);

			Assert.Equal(membersBefore, unit.Members.Count);
		}

		[Fact]
		public void OnCompile_NoComponents_LeavesImportsEmpty()
		{
			(var state, var root, var compilation) = TestHarness.Compile(@"
public class Plain { }
");
			ComponentsExtension ext = new();
			TestHarness.OnCompile(ext, compilation);

			List<INamedTypeSymbol> imports = ext.ContributeImports(root, state).ToList();
			Assert.Empty(imports);
		}

		[Fact]
		public void Name_IsComponents()
		{
			Assert.Equal("Components", new ComponentsExtension().Name);
		}
	}
}
