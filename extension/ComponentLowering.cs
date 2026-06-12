using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Transformer;
using RobloxCSharp.Transformer.AST;
using RobloxCSharp.Transformer.AST.Expressions;
using RobloxCSharp.Transformer.AST.Statements;
using RobloxCSharp.Transformer.Factory;

namespace RobloxCSharp.Extensions.Components
{
	/// <summary>
	/// Helpers for the Components-aware lowering passes inside
	/// <see cref="ComponentsExtension"/>. Identifies <see cref="Components.Component"/>
	/// subclasses by base-type symbol and emits the
	/// <c>Component.define(name)</c> scaffold the runtime expects in place of
	/// the regular Luau class metatable.
	/// </summary>
	public static class ComponentLowering
	{

		private const string ComponentTypeName = "Component";
		private const string ComponentNamespace = "Components";

		public static bool IsComponentSubclass(TransformerState state, TypeDeclarationSyntax syntax)
		{
			if (syntax.BaseList is null) return false;

			foreach (BaseTypeSyntax baseType in syntax.BaseList.Types)
			{
				if (state.SemanticModel.GetTypeInfo(baseType.Type).Type is not INamedTypeSymbol named) continue;
				if (named.Name == ComponentTypeName
					&& named.ContainingNamespace?.Name == ComponentNamespace)
				{
					return true;
				}
			}
			return false;
		}

		public static LuaNode Lower(TransformerState state, ClassDeclarationSyntax syntax)
		{
			string className = syntax.Identifier.ValueText;

			LuaClassDeclaration declaration = LuaFactory.ClassDeclaration(className);
			declaration.Members.Add(LuaFactory.LocalDeclaration(className));

			List<LuaNode> body = new();

			LuaInvocationExpression defineCall = LuaFactory.Invocation(
				LuaFactory.MemberAccess(ComponentTypeName, "define"));
			defineCall.Arguments.Add(LuaFactory.LiteralExpression(className));
			body.Add(LuaFactory.ExpressionStatement(
				LuaFactory.Assignment(
					SyntaxKind.SimpleAssignmentExpression,
					LuaFactory.Identifier(className),
					defineCall)));

			LuaTableExpression sfTable = BuildSerializedFieldsTable(state, syntax);
			if (sfTable.Elements.Count > 0)
			{
				body.Add(LuaFactory.ExpressionStatement(
					LuaFactory.Assignment(
						SyntaxKind.SimpleAssignmentExpression,
						LuaFactory.MemberAccess(className, "SerializedFields"),
						sfTable)));
			}

			ConstructorDeclarationSyntax userCtor = FindUserConstructor(syntax);
			body.Add(BuildCtorParams(state, className, userCtor));

			MemberLowering.EmitMembers(state, syntax, className, body);

			declaration.Members.Add(LuaFactory.Block(warpInDoEnd: true, body));
			return declaration;
		}

		private static ConstructorDeclarationSyntax FindUserConstructor(ClassDeclarationSyntax syntax)
		{
			foreach (MemberDeclarationSyntax member in syntax.Members)
			{
				if (member is ConstructorDeclarationSyntax ctor) return ctor;
			}
			return null;
		}

		private static LuaNode BuildCtorParams(TransformerState state, string className, ConstructorDeclarationSyntax ctor)
		{
			LuaTableExpression table = LuaFactory.Table(inline: true);
			if (ctor is not null)
			{
				foreach (ParameterSyntax param in ctor.ParameterList.Parameters)
				{
					// Params the container can't inject (primitives,
					// unresolvable types) still get an entry — `false` —
					// so the runtime's positional arg-building loop stays
					// aligned with the ctor's arity. ComponentsService
					// passes nil for those slots.
					table.Elements.Add(BuildCtorParamEntry(state, param));
				}
			}

			return LuaFactory.ExpressionStatement(
				LuaFactory.Assignment(SyntaxKind.SimpleAssignmentExpression,
					LuaFactory.MemberAccess(className, "__ctorParams"),
					table));
		}

		private static LuaNode BuildCtorParamEntry(TransformerState state, ParameterSyntax param)
		{
			if (param.Type is null) return LuaFactory.LiteralExpression(false);
			if (state.SemanticModel.GetTypeInfo(param.Type).Type is not INamedTypeSymbol named)
				return LuaFactory.LiteralExpression(false);
			if (named.SpecialType != SpecialType.None) return LuaFactory.LiteralExpression(false);
			if (named.TypeKind is not (TypeKind.Class or TypeKind.Interface))
				return LuaFactory.LiteralExpression(false);

			return named.TypeKind == TypeKind.Interface
				? (LuaNode)LuaFactory.LiteralExpression(named.Name)
				: LuaFactory.Identifier(named.Name);
		}

		private static LuaTableExpression BuildSerializedFieldsTable(TransformerState state, ClassDeclarationSyntax syntax)
		{
			LuaTableExpression outer = LuaFactory.Table(inline: false);

			foreach (MemberDeclarationSyntax member in syntax.Members)
			{
				switch (member)
				{

					case FieldDeclarationSyntax field
						when HasSerializedFieldAttribute(field.AttributeLists):
						foreach (VariableDeclaratorSyntax v in field.Declaration.Variables)
						{
							AddEntry(state, outer,
								memberName: v.Identifier.Text,
								typeSyntax: field.Declaration.Type,
								initializer: v.Initializer?.Value);
						}
						break;

					case PropertyDeclarationSyntax prop
						when HasSerializedFieldAttribute(prop.AttributeLists):
						AddEntry(state, outer,
							memberName: prop.Identifier.Text,
							typeSyntax: prop.Type,
							initializer: prop.Initializer?.Value);
						break;
				}
			}

			return outer;
		}

		private static void AddEntry(
			TransformerState state,
			LuaTableExpression outer,
			string memberName,
			TypeSyntax typeSyntax,
			ExpressionSyntax initializer)
		{
			ITypeSymbol type = state.SemanticModel.GetTypeInfo(typeSyntax).Type;
			LuaTableExpression inner = LuaFactory.Table(inline: true);

			if (CompositeLowering.TryGetInstanceConstraint(type, out string constraint))
			{
				AddKV(inner, "type", LuaFactory.LiteralExpression("instance"));
				AddKV(inner, "constraint", LuaFactory.LiteralExpression(constraint));
				AddKV(inner, "default", LuaFactory.LiteralExpression(""));
			}
			else if (CompositeLowering.TryGetComponentConstraint(type, out string componentName))
			{
				AddKV(inner, "type", LuaFactory.LiteralExpression("component"));
				AddKV(inner, "constraint", LuaFactory.LiteralExpression(componentName));
				AddKV(inner, "default", LuaFactory.LiteralExpression(""));
			}
			else if (CompositeLowering.TryGetEnumValues(type, out string enumName,
				out List<(string, int)> enumValues))
			{
				CompositeLowering.EmitEnumEntry(state, enumName, enumValues, initializer, inner);
			}
			else if (CompositeLowering.TryGetListElementType(type, out ITypeSymbol elementType))
			{
				if (CompositeLowering.TryGetListElementType(elementType, out _))
				{
					throw new InvalidOperationException(
						$"[SerializedField] '{memberName}' is a nested list. " +
						"Nested lists (List<List<X>>) aren't supported yet.");
				}
				LuaTableExpression elementEntry = LuaFactory.Table(inline: true);
				CompositeLowering.BuildElementEntry(state, elementType, memberName, elementEntry);
				AddKV(inner, "type", LuaFactory.LiteralExpression("list"));
				AddKV(inner, "element", elementEntry);
				AddKV(inner, "default", LuaFactory.LiteralExpression(0));
			}
			else if (CompositeLowering.IsCompositeCandidate(type))
			{
				LuaTableExpression nested = LuaFactory.Table(inline: false);
				CompositeLowering.PopulateFields(
					state, type,
					new HashSet<ITypeSymbol>(SymbolEqualityComparer.Default),
					memberName, nested);
				AddKV(inner, "type", LuaFactory.LiteralExpression("composite"));
				AddKV(inner, "fields", nested);
			}
			else if (CompositeLowering.TryMapPrimitive(type, out string luaType))
			{
				LuaExpression defaultExpr = initializer is null
					? CompositeLowering.DefaultForPrimitive(luaType)
					: state.Transform(initializer) as LuaExpression;
				AddKV(inner, "type", LuaFactory.LiteralExpression(luaType));
				AddKV(inner, "default", defaultExpr);
			}
			else
			{
				throw new InvalidOperationException(
					$"[SerializedField] '{memberName}' has unsupported type '{typeSyntax}'. " +
					"Supported: int / long / float / double / string / bool / Vector3 / Color3, Instance subclass, or a plain class of those.");
			}

			outer.Elements.Add(LuaFactory.ExpressionStatement(
				LuaFactory.Assignment(
					SyntaxKind.SimpleAssignmentExpression,
					LuaFactory.Identifier(memberName),
					inner)));
		}

		private static void AddKV(LuaTableExpression t, string key, LuaExpression value)
		{
			t.Elements.Add(LuaFactory.Assignment(
				SyntaxKind.SimpleAssignmentExpression,
				LuaFactory.Identifier(key),
				value));
		}

		internal static bool HasSerializedFieldAttribute(SyntaxList<AttributeListSyntax> attributeLists)
		{
			foreach (AttributeListSyntax al in attributeLists)
			{
				foreach (AttributeSyntax attr in al.Attributes)
				{
					string name = attr.Name.ToString();
					if (name == "SerializedField" || name == "SerializedFieldAttribute")
						return true;
				}
			}
			return false;
		}
	}
}
