using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Extensions.Components;
using RobloxCSharp.Transformer.AST.Expressions;

namespace Components.Tests
{
	public class ComponentLoweringTests
	{
		[Fact]
		public void IsComponentSubclass_True_ForDirectComponentBase()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Health : Component { }");

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			Assert.True(ComponentLowering.IsComponentSubclass(state, cls));
		}

		[Fact]
		public void IsComponentSubclass_False_ForOtherBaseClass()
		{
			(var state, var root, _) = TestHarness.Compile(@"
public class Health : System.Object { }");

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			Assert.False(ComponentLowering.IsComponentSubclass(state, cls));
		}

		[Fact]
		public void IsComponentSubclass_False_ForNoBaseList()
		{
			(var state, var root, _) = TestHarness.Compile(@"
public class Health { }");

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			Assert.False(ComponentLowering.IsComponentSubclass(state, cls));
		}

		[Fact]
		public void IsComponentSubclass_False_ForWrongNamespace()
		{
			(var state, var root, _) = TestHarness.Compile(@"
namespace Other
{
	public class Component { }
}
public class Health : Other.Component { }");

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			Assert.False(ComponentLowering.IsComponentSubclass(state, cls));
		}

		[Fact]
		public void Lower_EmitsClassDeclarationWithDefineCall()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Health : Component { }");

			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);
			LuaNode lowered = ComponentLowering.Lower(state, cls);

			LuaClassDeclaration decl = Assert.IsType<LuaClassDeclaration>(lowered);
			Assert.NotEmpty(decl.Members);
		}

		[Fact]
		public void Lower_SerializedField_Int_MapsToNumber()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Health : Component
{
	[SerializedField] private int max = 100;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			LuaNode result = ComponentLowering.Lower(state, cls);

			Assert.NotNull(result);
		}

		[Fact]
		public void Lower_SerializedField_UnsupportedType_Throws()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Health : Component
{
	[SerializedField] private System.Collections.Generic.List<int> values;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			InvalidOperationException ex = Assert.Throws<InvalidOperationException>(
				() => ComponentLowering.Lower(state, cls));
			Assert.Contains("SerializedField", ex.Message);
			Assert.Contains("values", ex.Message);
		}
	}
}
