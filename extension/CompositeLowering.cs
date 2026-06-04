using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Transformer;
using RobloxCSharp.Transformer.AST;
using RobloxCSharp.Transformer.AST.Expressions;
using RobloxCSharp.Transformer.Factory;

namespace RobloxCSharp.Extensions.Components
{
	/// <summary>
	/// Walks a non-Instance, non-primitive class type (a plain POCO) and
	/// emits a flattened <c>fields = { ... }</c> table for it, recursing
	/// into nested POCOs. Used by <see cref="ComponentLowering"/> when a
	/// <c>[SerializedField]</c> targets a user-defined class.
	/// </summary>
	public static class CompositeLowering
	{
		private const string RobloxApiNamespace = "RobloxCSharp.RobloxApi";
		private const string InstanceTypeName = "Instance";
		private const string ComponentTypeName = "Component";
		private const string ComponentNamespace = "Components";

		public static bool IsCompositeCandidate(ITypeSymbol type)
		{
			if (type is null) return false;
			if (type.TypeKind != TypeKind.Class) return false;
			if (type.SpecialType != SpecialType.None) return false;
			if (type is INamedTypeSymbol n && n.IsGenericType) return false;
			if (IsInstanceDerived(type)) return false;
			if (IsComponentDerived(type)) return false;
			return true;
		}

		public static bool TryGetInstanceConstraint(ITypeSymbol type, out string constraint)
		{
			constraint = null;
			for (ITypeSymbol cur = type; cur is not null; cur = cur.BaseType)
			{
				if (cur.Name == InstanceTypeName
					&& cur.ContainingNamespace?.ToDisplayString() == RobloxApiNamespace)
				{
					constraint = type.Name;
					return true;
				}
			}
			return false;
		}

		public static bool TryMapPrimitive(ITypeSymbol type, out string luaType)
		{
			switch (type?.SpecialType)
			{
				case SpecialType.System_Int32:
				case SpecialType.System_Int64:
				case SpecialType.System_Single:
				case SpecialType.System_Double:
					luaType = "number"; return true;
				case SpecialType.System_String:
					luaType = "string"; return true;
				case SpecialType.System_Boolean:
					luaType = "boolean"; return true;
			}
			luaType = null;
			return false;
		}

		public static LuaExpression DefaultForPrimitive(string luaType) => luaType switch
		{
			"number"  => LuaFactory.LiteralExpression(0),
			"string"  => LuaFactory.LiteralExpression(""),
			"boolean" => LuaFactory.LiteralExpression(false),
			_         => LuaFactory.LiteralExpression(null),
		};

		// Pulls enum member names + int values in declaration order.
		// Matches the converter's enum lowering (members emit as `Name =
		// <int>` in Luau), so the inspector can show the name while the
		// attribute stores the int.
		public static bool TryGetEnumValues(
			ITypeSymbol type,
			out string typeName,
			out List<(string Name, int Value)> values)
		{
			typeName = null;
			values = null;
			if (type is null || type.TypeKind != TypeKind.Enum) return false;

			typeName = type.Name;
			values = new List<(string, int)>();
			foreach (ISymbol m in type.GetMembers())
			{
				if (m is IFieldSymbol f && f.HasConstantValue && f.ConstantValue is not null)
				{
					values.Add((f.Name, Convert.ToInt32(f.ConstantValue)));
				}
			}
			return true;
		}

		// Builds the SerializedFields entry for an enum field. `initializer`
		// (if non-null) is evaluated as a constant to pick the default
		// value; otherwise the first member's value wins.
		public static void EmitEnumEntry(
			TransformerState state,
			string typeName,
			List<(string Name, int Value)> values,
			ExpressionSyntax initializer,
			LuaTableExpression entry)
		{
			int defaultValue = values.Count > 0 ? values[0].Value : 0;
			if (initializer is not null)
			{
				Optional<object> constVal = state.SemanticModel.GetConstantValue(initializer);
				if (constVal.HasValue && constVal.Value is not null)
				{
					defaultValue = Convert.ToInt32(constVal.Value);
				}
			}

			AddKV(entry, "type", LuaFactory.LiteralExpression("enum"));
			AddKV(entry, "constraint", LuaFactory.LiteralExpression(typeName));

			LuaTableExpression valuesArr = LuaFactory.Table(inline: false);
			foreach ((string name, int value) in values)
			{
				LuaTableExpression item = LuaFactory.Table(inline: true);
				AddKV(item, "name", LuaFactory.LiteralExpression(name));
				AddKV(item, "value", LuaFactory.LiteralExpression(value));
				valuesArr.Elements.Add(item);
			}
			AddKV(entry, "values", valuesArr);
			AddKV(entry, "default", LuaFactory.LiteralExpression(defaultValue));
		}


		// Fills `fields` with one entry per public instance field /
		// settable auto-property of `type`. `path` is the dotted name
		// used in error messages.
		public static void PopulateFields(
			TransformerState state,
			ITypeSymbol type,
			HashSet<ITypeSymbol> visited,
			string path,
			LuaTableExpression fields)
		{
			if (!visited.Add(type))
			{
				throw new InvalidOperationException(
					$"[SerializedField] '{path}' has a cyclic type '{type.Name}'.");
			}

			foreach (ISymbol member in type.GetMembers())
			{
				if (member.DeclaredAccessibility != Accessibility.Public) continue;
				if (member.IsStatic) continue;

				ITypeSymbol memberType;
				string memberName;
				ExpressionSyntax initializer;

				if (member is IFieldSymbol fs && !fs.IsConst)
				{
					memberType = fs.Type;
					memberName = fs.Name;
					initializer = (fs.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax()
						as VariableDeclaratorSyntax)?.Initializer?.Value;
				}
				else if (member is IPropertySymbol ps && ps.SetMethod is not null)
				{
					memberType = ps.Type;
					memberName = ps.Name;
					initializer = (ps.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax()
						as PropertyDeclarationSyntax)?.Initializer?.Value;
				}
				else continue;

				LuaTableExpression entry = LuaFactory.Table(inline: true);
				BuildEntry(state, memberType, visited, $"{path}.{memberName}", initializer, entry);

				fields.Elements.Add(LuaFactory.ExpressionStatement(
					LuaFactory.Assignment(
						SyntaxKind.SimpleAssignmentExpression,
						LuaFactory.Identifier(memberName),
						entry)));
			}

			visited.Remove(type);
		}

		private static void BuildEntry(
			TransformerState state,
			ITypeSymbol type,
			HashSet<ITypeSymbol> visited,
			string path,
			ExpressionSyntax initializer,
			LuaTableExpression entry)
		{
			if (TryGetInstanceConstraint(type, out string constraint))
			{
				AddKV(entry, "type", LuaFactory.LiteralExpression("instance"));
				AddKV(entry, "constraint", LuaFactory.LiteralExpression(constraint));
				AddKV(entry, "default", LuaFactory.LiteralExpression(""));
				return;
			}

			if (TryGetEnumValues(type, out string enumName, out List<(string, int)> enumValues))
			{
				EmitEnumEntry(state, enumName, enumValues, initializer, entry);
				return;
			}

			if (IsCompositeCandidate(type))
			{
				LuaTableExpression nested = LuaFactory.Table(inline: false);
				PopulateFields(state, type, visited, path, nested);
				AddKV(entry, "type", LuaFactory.LiteralExpression("composite"));
				AddKV(entry, "fields", nested);
				return;
			}

			if (!TryMapPrimitive(type, out string luaType))
			{
				throw new InvalidOperationException(
					$"[SerializedField] '{path}' has unsupported type '{type?.Name}'. " +
					"Supported: int / long / float / double / string / bool, Instance subclass, or a plain class of those.");
			}

			LuaExpression defaultExpr = initializer is null
				? DefaultForPrimitive(luaType)
				: state.Transform(initializer) as LuaExpression;

			AddKV(entry, "type", LuaFactory.LiteralExpression(luaType));
			AddKV(entry, "default", defaultExpr);
		}

		private static void AddKV(LuaTableExpression t, string key, LuaExpression value)
		{
			t.Elements.Add(LuaFactory.Assignment(
				SyntaxKind.SimpleAssignmentExpression,
				LuaFactory.Identifier(key),
				value));
		}

		private static bool IsInstanceDerived(ITypeSymbol type) =>
			TryGetInstanceConstraint(type, out _);

		private static bool IsComponentDerived(ITypeSymbol type)
		{
			for (ITypeSymbol cur = type; cur is not null; cur = cur.BaseType)
			{
				if (cur.Name == ComponentTypeName
					&& cur.ContainingNamespace?.Name == ComponentNamespace)
					return true;
			}
			return false;
		}
	}
}
