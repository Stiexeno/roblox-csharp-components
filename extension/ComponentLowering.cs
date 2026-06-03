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

			foreach (MemberDeclarationSyntax member in syntax.Members)
			{
				switch (member)
				{
					case MethodDeclarationSyntax method:
						body.Add(state.Transform(method));
						break;
					case ConstructorDeclarationSyntax ctorSyntax:
						LuaConstructorDeclaration luaCtor =
							(LuaConstructorDeclaration)state.Transform(ctorSyntax);
						luaCtor.BaseCall = null;
						body.Add(luaCtor);
						break;
					case FieldDeclarationSyntax field when IsStaticOrConst(field):
						body.Add(state.Transform(field));
						break;
				}
			}

			declaration.Members.Add(LuaFactory.Block(warpInDoEnd: true, body));
			return declaration;
		}

		private static bool IsStaticOrConst(FieldDeclarationSyntax field)
		{
			foreach (SyntaxToken modifier in field.Modifiers)
			{
				if (modifier.IsKind(SyntaxKind.StaticKeyword)
					|| modifier.IsKind(SyntaxKind.ConstKeyword))
				{
					return true;
				}
			}
			return false;
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
					if (param.Type is null) continue;
					if (state.SemanticModel.GetTypeInfo(param.Type).Type is not INamedTypeSymbol named) continue;
					if (named.SpecialType != SpecialType.None) continue;
					if (named.TypeKind is not (TypeKind.Class or TypeKind.Interface)) continue;

					table.Elements.Add(named.TypeKind == TypeKind.Interface
						? (LuaNode)LuaFactory.LiteralExpression(named.Name)
						: LuaFactory.Identifier(named.Name));
				}
			}

			return LuaFactory.ExpressionStatement(
				LuaFactory.Assignment(SyntaxKind.SimpleAssignmentExpression,
					LuaFactory.MemberAccess(className, "__ctorParams"),
					table));
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
			string luaType = MapToLuaType(state, typeSyntax, memberName);

			LuaExpression defaultExpr = initializer is null
				? LuaFactory.LiteralExpression(null)
				: state.Transform(initializer) as LuaExpression;

			LuaTableExpression inner = LuaFactory.Table(inline: true);
			inner.Elements.Add(LuaFactory.Assignment(
				SyntaxKind.SimpleAssignmentExpression,
				LuaFactory.Identifier("type"),
				LuaFactory.LiteralExpression(luaType)));
			inner.Elements.Add(LuaFactory.Assignment(
				SyntaxKind.SimpleAssignmentExpression,
				LuaFactory.Identifier("default"),
				defaultExpr));

			outer.Elements.Add(LuaFactory.ExpressionStatement(
				LuaFactory.Assignment(
					SyntaxKind.SimpleAssignmentExpression,
					LuaFactory.Identifier(memberName),
					inner)));
		}

		private static string MapToLuaType(TransformerState state, TypeSyntax typeSyntax, string memberName)
		{
			ITypeSymbol type = state.SemanticModel.GetTypeInfo(typeSyntax).Type;
			switch (type?.SpecialType)
			{
				case SpecialType.System_Int32:
				case SpecialType.System_Int64:
				case SpecialType.System_Single:
				case SpecialType.System_Double:
					return "number";
				case SpecialType.System_String:
					return "string";
				case SpecialType.System_Boolean:
					return "boolean";
			}
			throw new InvalidOperationException(
				$"[SerializedField] '{memberName}' has unsupported type '{typeSyntax}'. " +
				"v1 only supports int / long / float / double / string / bool.");
		}

		private static bool HasSerializedFieldAttribute(SyntaxList<AttributeListSyntax> attributeLists)
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
