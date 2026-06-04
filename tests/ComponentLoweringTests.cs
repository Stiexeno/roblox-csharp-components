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
	[SerializedField] private System.Collections.Generic.Dictionary<string, int> values;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			InvalidOperationException ex = Assert.Throws<InvalidOperationException>(
				() => ComponentLowering.Lower(state, cls));
			Assert.Contains("SerializedField", ex.Message);
			Assert.Contains("values", ex.Message);
		}

		[Fact]
		public void Lower_SerializedField_Instance_EmitsInstanceTypeAndConstraint()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
using RobloxCSharp.RobloxApi;
public class Anchor : Component
{
	[SerializedField] private Instance target;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("target", rendered);
			Assert.Contains("type = \"instance\"", rendered);
			Assert.Contains("constraint = \"Instance\"", rendered);
			Assert.Contains("default = \"\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_BasePartSubclass_CarriesConcreteConstraint()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
using RobloxCSharp.RobloxApi;
public class Anchor : Component
{
	[SerializedField] private BasePart target;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root);

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"instance\"", rendered);
			Assert.Contains("constraint = \"BasePart\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_Poco_EmitsCompositeFields()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Stats
{
	public int Health = 100;
	public int Mana = 50;
}
public class Player : Component
{
	[SerializedField] private Stats stats;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Player");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"composite\"", rendered);
			Assert.Contains("Health", rendered);
			Assert.Contains("Mana", rendered);
			Assert.Contains("default = 100", rendered);
			Assert.Contains("default = 50", rendered);
		}

		[Fact]
		public void Lower_SerializedField_NestedPoco_FlattensThroughComposite()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Inner { public int X = 7; }
public class Outer { public Inner Sub; }
public class Box : Component
{
	[SerializedField] private Outer outer;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Box");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			// Outer composite contains Sub composite which contains X = 7.
			Assert.Contains("Sub", rendered);
			Assert.Contains("X", rendered);
			Assert.Contains("default = 7", rendered);
		}

		[Fact]
		public void Lower_SerializedField_PocoMixesInstanceLeaf()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
using RobloxCSharp.RobloxApi;
public class Refs { public BasePart Anchor; public int Slot = 1; }
public class Beacon : Component
{
	[SerializedField] private Refs refs;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Beacon");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"composite\"", rendered);
			Assert.Contains("type = \"instance\"", rendered);
			Assert.Contains("constraint = \"BasePart\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_CyclicPoco_Throws()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class A { public B Next; }
public class B { public A Back; }
public class Loop : Component
{
	[SerializedField] private A a;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Loop");

			InvalidOperationException ex = Assert.Throws<InvalidOperationException>(
				() => ComponentLowering.Lower(state, cls));
			Assert.Contains("cyclic", ex.Message);
		}

		[Fact]
		public void Lower_SerializedField_Enum_EmitsEnumEntryAndValues()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public enum MoveState { Idle, Running, Jumping }
public class Mover : Component
{
	[SerializedField] private MoveState state;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Mover");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"enum\"", rendered);
			Assert.Contains("constraint = \"MoveState\"", rendered);
			Assert.Contains("name = \"Idle\"", rendered);
			Assert.Contains("name = \"Running\"", rendered);
			Assert.Contains("name = \"Jumping\"", rendered);
			Assert.Contains("value = 0", rendered);
			Assert.Contains("value = 1", rendered);
			Assert.Contains("value = 2", rendered);
			Assert.Contains("default = 0", rendered);
		}

		[Fact]
		public void Lower_SerializedField_EnumWithInitializer_UsesInitializerOrdinal()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public enum MoveState { Idle, Running, Jumping }
public class Mover : Component
{
	[SerializedField] private MoveState state = MoveState.Running;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Mover");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("default = 1", rendered);
		}

		[Fact]
		public void Lower_SerializedField_EnumInsideComposite_RecursesIntoEnum()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public enum Color { Red, Green, Blue }
public class Skin { public Color Tone; }
public class Avatar : Component
{
	[SerializedField] private Skin skin;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Avatar");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"composite\"", rendered);
			Assert.Contains("type = \"enum\"", rendered);
			Assert.Contains("constraint = \"Color\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_ListOfInt_EmitsListWithNumberElement()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Box : Component
{
	[SerializedField] private System.Collections.Generic.List<int> scores;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Box");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"list\"", rendered);
			Assert.Contains("type = \"number\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_ArrayOfInt_TreatedAsList()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Box : Component
{
	[SerializedField] private int[] scores;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Box");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"list\"", rendered);
			Assert.Contains("type = \"number\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_ListOfInstance_ElementIsInstanceWithConstraint()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
using RobloxCSharp.RobloxApi;
public class Spawner : Component
{
	[SerializedField] private System.Collections.Generic.List<BasePart> points;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Spawner");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"list\"", rendered);
			Assert.Contains("type = \"instance\"", rendered);
			Assert.Contains("constraint = \"BasePart\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_ListOfPoco_ElementIsComposite()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Item { public int Id; public string Name; }
public class Bag : Component
{
	[SerializedField] private System.Collections.Generic.List<Item> items;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Bag");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"list\"", rendered);
			Assert.Contains("type = \"composite\"", rendered);
			Assert.Contains("Id", rendered);
			Assert.Contains("Name", rendered);
		}

		[Fact]
		public void Lower_SerializedField_ListOfEnum_ElementIsEnum()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public enum Tag { A, B, C }
public class Tagged : Component
{
	[SerializedField] private System.Collections.Generic.List<Tag> tags;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Tagged");

			string rendered = new LuaRenderer().Render(ComponentLowering.Lower(state, cls));

			Assert.Contains("type = \"list\"", rendered);
			Assert.Contains("type = \"enum\"", rendered);
			Assert.Contains("constraint = \"Tag\"", rendered);
		}

		[Fact]
		public void Lower_SerializedField_NestedList_Throws()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Grid : Component
{
	[SerializedField] private System.Collections.Generic.List<System.Collections.Generic.List<int>> rows;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Grid");

			InvalidOperationException ex = Assert.Throws<InvalidOperationException>(
				() => ComponentLowering.Lower(state, cls));
			Assert.Contains("nested list", ex.Message);
		}

		[Fact]
		public void Lower_SerializedField_PocoWithUnsupportedLeaf_Throws()
		{
			(var state, var root, _) = TestHarness.Compile(@"
using Components;
public class Bag { public System.Collections.Generic.Dictionary<string, int> Items; }
public class Backpack : Component
{
	[SerializedField] private Bag bag;
}");
			ClassDeclarationSyntax cls = TestHarness.FirstNode<ClassDeclarationSyntax>(root, name: "Backpack");

			InvalidOperationException ex = Assert.Throws<InvalidOperationException>(
				() => ComponentLowering.Lower(state, cls));
			Assert.Contains("Items", ex.Message);
		}
	}
}
