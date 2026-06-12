using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Transformer;
using RobloxCSharp.Transformer.AST;
using RobloxCSharp.Transformer.AST.Statements;
using RobloxCSharp.Transformer.Factory;

namespace RobloxCSharp.Extensions.Components
{
	/// <summary>
	/// Member routing for <see cref="ComponentLowering"/>. Mirrors the core
	/// transpiler's ClassDeclarationTransformer: methods and bodied
	/// properties emit in place; instance fields / auto-properties with
	/// initializers are collected into the constructor's field-init block
	/// (so <c>private float timer = 5f;</c> is set on <c>self</c> before
	/// the ctor body runs). <c>[SerializedField]</c> members are skipped —
	/// they're attribute-backed through <c>Component.spawn</c>, and
	/// re-initializing them in the ctor would stomp inspector-edited
	/// values on every spawn.
	/// </summary>
	internal static class MemberLowering
	{
		public static void EmitMembers(
			TransformerState state,
			ClassDeclarationSyntax syntax,
			string className,
			List<LuaNode> body)
		{
			List<LuaNode> instanceInits = new();
			LuaConstructorDeclaration ctor = null;

			foreach (MemberDeclarationSyntax member in syntax.Members)
			{
				switch (member)
				{
					case MethodDeclarationSyntax method:
						body.Add(state.Transform(method));
						break;

					case ConstructorDeclarationSyntax ctorSyntax:
						ctor = (LuaConstructorDeclaration)state.Transform(ctorSyntax);
						// Component.spawn builds `self`; there is no Luau
						// base class to chain into.
						ctor.BaseCall = null;
						break;

					case FieldDeclarationSyntax field
						when !ComponentLowering.HasSerializedFieldAttribute(field.AttributeLists):
						Route(state.Transform(field), body, instanceInits);
						break;

					case PropertyDeclarationSyntax prop
						when !ComponentLowering.HasSerializedFieldAttribute(prop.AttributeLists):
						Route(state.Transform(prop), body, instanceInits);
						break;
				}
			}

			// Field initializers need a constructor to live in even when the
			// user didn't write one — the runtime calls definition.constructor
			// when present, so a synthetic empty ctor is enough.
			if (ctor is null && instanceInits.Count > 0)
			{
				ctor = new LuaConstructorDeclaration(className, LuaFactory.Block());
			}
			if (ctor is not null)
			{
				ctor.FieldInitializations.AddRange(instanceInits);
				body.Add(ctor);
			}
		}

		// Same shape as the core ClassDeclarationTransformer.RouteResult,
		// minus the constructor-overload and static-initializer bookkeeping
		// components don't need.
		private static void Route(LuaNode node, List<LuaNode> body, List<LuaNode> instanceInits)
		{
			switch (node)
			{
				case LuaBlock group when !group.WrapInDoEnd:
					foreach (LuaNode child in group.Statements)
					{
						Route(child, body, instanceInits);
					}
					return;

				case LuaFieldDeclaration field when !field.IsStatic && field.Initializer is not null:
					instanceInits.Add(field);
					return;

				case LuaPropertyDeclaration { IsAutoProperty: true } autoProp:
					if (!autoProp.IsStatic && autoProp.Initializer is not null)
						instanceInits.Add(autoProp);
					else if (autoProp.Initializer is not null)
						body.Add(autoProp);
					return;

				default:
					body.Add(node);
					return;
			}
		}
	}
}
