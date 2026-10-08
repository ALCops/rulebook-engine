// Stub of ALCops.LinterCop.dll. LC0015 is Info in STUB_ALCOPS_V1 (1.3.1) and Warning from 1.4.0-beta.1 on, where
// LC0100 is new. LC0000 is field-only (the analyzer exception descriptor), LC0089 and LC0089i come from one
// analyzer, ZZ0001 has a prefix the engine does not know.
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace ALCops.LinterCop
{
    public static class DiagnosticDescriptors
    {
        private const string Docs = "https://alcops.dev/docs/analyzers/lintercop/";
        public static readonly DiagnosticDescriptor AnalyzerException = new DiagnosticDescriptor("LC0000", "An analyzer exception occurred", "Analyzer", DiagnosticSeverity.Info, true, Docs + "lc0000/");
#if STUB_ALCOPS_V1
        public static readonly DiagnosticDescriptor LC0015 = new DiagnosticDescriptor("LC0015", "Permission sets\n  should cover every object", "Design", DiagnosticSeverity.Info, true, Docs + "lc0015/");
#else
        public static readonly DiagnosticDescriptor LC0015 = new DiagnosticDescriptor("LC0015", "Permission sets\n  should cover every object", "Design", DiagnosticSeverity.Warning, true, Docs + "lc0015/");
        public static readonly DiagnosticDescriptor LC0100 = new DiagnosticDescriptor("LC0100", "A rule new in 1.4.0", "Design", DiagnosticSeverity.Info, true, Docs + "lc0100/");
#endif
        public static readonly DiagnosticDescriptor LC0089 = new DiagnosticDescriptor("LC0089", "Cognitive complexity", "Design", DiagnosticSeverity.Warning, true, Docs + "lc0089/");
        public static readonly DiagnosticDescriptor LC0089i = new DiagnosticDescriptor("LC0089i", "Cognitive complexity (info)", "Design", DiagnosticSeverity.Info, true, Docs + "lc0089/");
        public static readonly DiagnosticDescriptor ZZ0001 = new DiagnosticDescriptor("ZZ0001", "A rule with an unknown prefix", "Design", DiagnosticSeverity.Info, true, null);
    }

    public sealed class PermissionSetAnalyzer : DiagnosticAnalyzer
    {
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(DiagnosticDescriptors.LC0015);
    }

#if !STUB_ALCOPS_V1
    public sealed class NewRuleAnalyzer : DiagnosticAnalyzer
    {
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(DiagnosticDescriptors.LC0100);
    }
#endif

    public sealed class CognitiveComplexityAnalyzer : DiagnosticAnalyzer
    {
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(DiagnosticDescriptors.LC0089, DiagnosticDescriptors.LC0089i, DiagnosticDescriptors.ZZ0001);
    }
}
