using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Common.Diagnostics;
using RobloxCSharp.Plugins;
using RobloxCSharp.Rojo;
using RobloxCSharp.Transformer;
using RobloxCSharp.Transformer.AST;
using RobloxCSharp.Transformer.AST.Expressions;
using RobloxCSharp.Transformer.AST.Statements;
using RobloxCSharp.Transformer.Extensibility;
using RobloxCSharp.Transformer.Factory;

namespace RobloxCSharp.Extensions.Components
{

	public sealed class ComponentsExtension : IRobloxCSharpExtension
	{

		public const string InstallerContainerVar = "_container";

		private const string ComponentsServiceTypeName = "ComponentsService";
		private const string ComponentsServiceMetadataName = "Components.ComponentsService";
		private const string InstallerTypeName = "Installer";
		private const string InstallerNamespace = "DependencyInjection";
		private const string ServerAttributeName = "ServerAttribute";
		private const string ClientAttributeName = "ClientAttribute";

		private List<INamedTypeSymbol> _componentClasses = new();
		private INamedTypeSymbol _componentsServiceSymbol;

		public string Name => "Components";

		public void OnCompile(Compilation compilation, IReadOnlyList<Plugin> plugins, DiagnosticBag diagnostics)
		{
			_componentClasses = CollectComponentClasses(compilation);
			_componentsServiceSymbol = compilation.GetTypeByMetadataName(ComponentsServiceMetadataName);
		}

		public LuaNode TryRewrite(SyntaxNode syntax, TransformerState state)
		{
			if (syntax is ClassDeclarationSyntax cls && ComponentLowering.IsComponentSubclass(state, cls))
			{
				return ComponentLowering.Lower(state, cls);
			}
			return null;
		}

		public IEnumerable<INamedTypeSymbol> ContributeImports(CompilationUnitSyntax syntax, TransformerState state)
		{
			if (_componentClasses.Count == 0) yield break;
			if (!IsDiInstallerUnit(syntax, state.SemanticModel)) yield break;

			if (_componentsServiceSymbol is not null) yield return _componentsServiceSymbol;
			foreach (INamedTypeSymbol cls in _componentClasses) yield return cls;
		}

		public IEnumerable<INamedTypeSymbol> SuppressImports(CompilationUnitSyntax syntax, TransformerState state)
		{
			yield break;
		}

		public void OnUnitTransformed(LuaCompilationUnit unit, CompilationUnitSyntax syntax, TransformerState state)
		{
			if (_componentClasses.Count == 0) return;
			if (!IsDiInstallerUnit(syntax, state.SemanticModel)) return;

			string componentsServiceVar = state.GenerateTempName("componentsService");

			LuaInvocationExpression svcNew = LuaFactory.Invocation(
				LuaFactory.MemberAccess(ComponentsServiceTypeName, "new"));
			svcNew.Arguments.Add(LuaFactory.Identifier(InstallerContainerVar));
			unit.Members.Add(LuaFactory.LocalDeclaration(componentsServiceVar, svcNew));

			foreach (INamedTypeSymbol componentClass in _componentClasses)
			{
				LuaInvocationExpression registerCall = LuaFactory.Invocation(
					LuaFactory.MemberAccess(
						LuaFactory.Identifier(componentsServiceVar),
						"Register",
						isMethodCall: true));
				registerCall.Arguments.Add(LuaFactory.Identifier(componentClass.Name));
				unit.Members.Add(LuaFactory.ExpressionStatement(registerCall));
			}
		}

		public void EmitArtifacts(string outDir, IReadOnlyList<Plugin> plugins, RojoResolver resolver, DiagnosticBag diagnostics)
		{
		}

		private static bool IsDiInstallerUnit(CompilationUnitSyntax syntax, SemanticModel semanticModel)
		{
			foreach (ClassDeclarationSyntax cls in syntax.DescendantNodes().OfType<ClassDeclarationSyntax>())
			{
				if (semanticModel.GetDeclaredSymbol(cls) is not INamedTypeSymbol sym) continue;

				bool isScript = false;
				bool isInstaller = false;
				INamedTypeSymbol current = sym;
				while (current is not null)
				{
					foreach (AttributeData attr in current.GetAttributes())
					{
						string name = attr.AttributeClass?.Name;
						if (name == ServerAttributeName || name == ClientAttributeName) isScript = true;
					}
					if (current.Name == InstallerTypeName
						&& current.ContainingNamespace?.Name == InstallerNamespace)
					{
						isInstaller = true;
					}
					current = current.BaseType;
				}

				if (isScript && isInstaller) return true;
			}
			return false;
		}

		private static List<INamedTypeSymbol> CollectComponentClasses(Compilation compilation)
		{
			List<INamedTypeSymbol> result = new();

			foreach (SyntaxTree tree in compilation.SyntaxTrees)
			{
				SemanticModel sm = compilation.GetSemanticModel(tree);
				foreach (ClassDeclarationSyntax cls in tree.GetRoot()
					.DescendantNodes()
					.OfType<ClassDeclarationSyntax>())
				{
					if (cls.BaseList is null) continue;

					foreach (BaseTypeSyntax baseType in cls.BaseList.Types)
					{
						if (sm.GetTypeInfo(baseType.Type).Type is not INamedTypeSymbol named) continue;
						if (named.Name == "Component"
							&& named.ContainingNamespace?.Name == "Components")
						{
							if (sm.GetDeclaredSymbol(cls) is INamedTypeSymbol clsSymbol) result.Add(clsSymbol);
							break;
						}
					}
				}
			}

			return result;
		}
	}
}
