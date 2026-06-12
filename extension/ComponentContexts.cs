using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using RobloxCSharp.Rojo;
using RobloxCSharp.Transformer;

namespace RobloxCSharp.Extensions.Components
{
	/// <summary>
	/// Server/client/shared classification for component modules and DI
	/// installer units, derived from Rojo placement: C# source path →
	/// output .luau path (<see cref="PathTranslator"/>) → DataModel path
	/// (<see cref="RojoResolver"/>) → <see cref="NetworkType"/>. Drives
	/// which installer a component registers into, so a client-only module
	/// never gets required from the server boot script (broken require
	/// path) and a Workspace instance doesn't spawn once per context.
	/// </summary>
	internal static class ComponentContexts
	{
		public static NetworkType OfUnit(CompilationUnitSyntax syntax, TransformerState state)
			=> OfPath(syntax.SyntaxTree.FilePath, state);

		public static NetworkType OfComponent(
			INamedTypeSymbol cls,
			TransformerState state,
			Dictionary<INamedTypeSymbol, NetworkType> cache)
		{
			if (cache.TryGetValue(cls, out NetworkType cached)) return cached;

			string path = cls.DeclaringSyntaxReferences.FirstOrDefault()?.SyntaxTree?.FilePath;
			NetworkType context = OfPath(path, state);
			cache[cls] = context;
			return context;
		}

		// Registration rule:
		//   - Installer context Unknown (no Rojo project — unit tests,
		//     synthetic compiles): register everything, the legacy shape.
		//   - Server/client component: only the same-context installer.
		//   - Shared component (ReplicatedStorage): server installer only.
		//     Both contexts can require a shared module, so registering it
		//     in both installers would double-spawn every Workspace
		//     instance; the server is the deterministic pick (the
		//     authoritative side, and the one that always sees tagged
		//     world objects). Documented in the README.
		public static bool ShouldRegister(NetworkType component, NetworkType installer)
		{
			if (installer == NetworkType.Unknown) return true;
			if (component == NetworkType.Unknown) return installer == NetworkType.Server;
			return component == installer;
		}

		private static NetworkType OfPath(string sourcePath, TransformerState state)
		{
			if (string.IsNullOrEmpty(sourcePath)) return NetworkType.Unknown;
			if (state.RojoResolver is null || state.PathTranslator is null) return NetworkType.Unknown;

			string outputPath = state.PathTranslator.GetOutputPath(sourcePath);
			string[] rbxPath = state.RojoResolver.GetRbxPathFromFilePath(outputPath);
			if (rbxPath is null) return NetworkType.Unknown;

			return state.RojoResolver.GetNetworkType(rbxPath);
		}
	}
}
