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
using RobloxCSharp.Transformer.Symbols;

namespace RobloxCSharp.Extensions.Components
{
	/// <summary>
	/// Transpiler hook that detects every <see cref="Components.Component"/>
	/// subclass at compile time and appends an auto-registration tail to the
	/// project's <c>Installer</c> boot script — one
	/// <c>ComponentsService:Register(T)</c> call per discovered subclass — so
	/// user code never has to register components by hand.
	/// </summary>
	public sealed class ComponentsExtension : IRobloxCSharpExtension
	{

		public const string InstallerContainerVar = "_container";

		private const string ComponentsServiceTypeName = "ComponentsService";
		private const string ComponentsServiceMetadataName = "Components.ComponentsService";
		private const string SerializedFieldMetadataName = "Components.SerializedFieldAttribute";
		private const string InstallerTypeName = "Installer";
		private const string InstallerNamespace = "DependencyInjection";
		private const string ServerAttributeName = "ServerAttribute";
		private const string ClientAttributeName = "ClientAttribute";

		private List<INamedTypeSymbol> _componentClasses = new();
		private INamedTypeSymbol _componentsServiceSymbol;
		private INamedTypeSymbol _serializedFieldSymbol;
		private readonly Dictionary<INamedTypeSymbol, NetworkType> _componentContexts =
			new(SymbolEqualityComparer.Default);
		private readonly HashSet<INamedTypeSymbol> _registeredComponents =
			new(SymbolEqualityComparer.Default);
		private bool _sawInstallerUnit;

		public string Name => "Components";

		public void OnCompile(Compilation compilation, IReadOnlyList<Plugin> plugins, DiagnosticBag diagnostics)
		{
			_componentClasses = CollectComponentClasses(compilation);
			_componentsServiceSymbol = compilation.GetTypeByMetadataName(ComponentsServiceMetadataName);
			_serializedFieldSymbol = compilation.GetTypeByMetadataName(SerializedFieldMetadataName);
			_componentContexts.Clear();
			_registeredComponents.Clear();
			_sawInstallerUnit = false;
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

			List<INamedTypeSymbol> matched = ComponentsForUnit(syntax, state);
			if (matched.Count == 0) yield break;

			if (_componentsServiceSymbol is not null) yield return _componentsServiceSymbol;
			foreach (INamedTypeSymbol cls in matched) yield return cls;
		}

		public IEnumerable<INamedTypeSymbol> SuppressImports(CompilationUnitSyntax syntax, TransformerState state)
		{
			// [SerializedField] is compile-time metadata only — there is no
			// runtime/SerializedFieldAttribute.luau, so a would-be import
			// would require a module that doesn't exist.
			if (_serializedFieldSymbol is not null) yield return _serializedFieldSymbol;
		}

		public void OnUnitTransformed(LuaCompilationUnit unit, CompilationUnitSyntax syntax, TransformerState state)
		{
			if (_componentClasses.Count == 0) return;
			if (!IsDiInstallerUnit(syntax, state.SemanticModel)) return;

			_sawInstallerUnit = true;

			List<INamedTypeSymbol> matched = ComponentsForUnit(syntax, state);
			if (matched.Count == 0) return;

			string componentsServiceVar = state.GenerateTempName("componentsService");

			LuaInvocationExpression svcNew = LuaFactory.Invocation(
				LuaFactory.MemberAccess(ComponentsServiceTypeName, "new"));
			svcNew.Arguments.Add(LuaFactory.Identifier(InstallerContainerVar));
			unit.Members.Add(LuaFactory.LocalDeclaration(componentsServiceVar, svcNew));

			foreach (INamedTypeSymbol componentClass in matched)
			{
				_registeredComponents.Add(componentClass);

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
			if (_componentClasses.Count == 0) return;

			List<INamedTypeSymbol> missed = _componentClasses
				.Where(cls => !_registeredComponents.Contains(cls))
				.ToList();
			if (missed.Count == 0) return;

			string names = string.Join(", ", missed.Select(cls => cls.Name));
			string message = _sawInstallerUnit
				? $"Component class(es) {names} were not auto-registered: no [Server]/[Client] DI Installer matches their context, so they will never spawn."
				: $"Component class(es) {names} exist but no [Server]/[Client] DI Installer was found — nothing registers them, so they will never spawn.";

			if (missed[0].DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax() is SyntaxNode node)
			{
				diagnostics.ReportSemanticsDivergence(node, message);
			}
		}

		// Components that belong in this installer unit's registration
		// tail: same Rojo context as the component's own module, with
		// shared components going server-side. See ComponentContexts.
		private List<INamedTypeSymbol> ComponentsForUnit(CompilationUnitSyntax syntax, TransformerState state)
		{
			NetworkType unitContext = ComponentContexts.OfUnit(syntax, state);
			List<INamedTypeSymbol> matched = new();
			foreach (INamedTypeSymbol cls in _componentClasses)
			{
				NetworkType componentContext = ComponentContexts.OfComponent(cls, state, _componentContexts);
				if (ComponentContexts.ShouldRegister(componentContext, unitContext))
				{
					matched.Add(cls);
				}
			}
			return matched;
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
