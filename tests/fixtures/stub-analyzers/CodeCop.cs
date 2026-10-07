// Stub of Microsoft.Dynamics.Nav.CodeCop.dll: AA0001 advertised by two analyzers, AA0002 field-only, AA0003
// deprecated, an abstract analyzer and one without a parameterless constructor (both skipped).
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace Microsoft.Dynamics.Nav.CodeCop
{
    internal static class Descriptors
    {
        private const string Link = "https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/analyzers/codecop-aa0001?wt.mc_id=stub";
        public static readonly DiagnosticDescriptor AA0001 = new DiagnosticDescriptor("AA0001", "There must be exactly one space  character on each side of a binary operator", "Readability", DiagnosticSeverity.Warning, true, Link);
        public static readonly DiagnosticDescriptor AA0002 = new DiagnosticDescriptor("AA0002", "Field-only descriptor", "Readability", DiagnosticSeverity.Info, false);
        public static readonly DiagnosticDescriptor AA0003 = new DiagnosticDescriptor("AA0003", "Deprecated rule", "Readability", DiagnosticSeverity.Warning, true, null, true);
    }

    public sealed class SpacingAnalyzer : DiagnosticAnalyzer
    {
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Descriptors.AA0001, Descriptors.AA0003);
    }

    public sealed class SecondSpacingAnalyzer : DiagnosticAnalyzer
    {
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Descriptors.AA0001);
    }

    public abstract class AbstractAnalyzer : DiagnosticAnalyzer
    {
    }

    public sealed class NoDefaultConstructorAnalyzer : DiagnosticAnalyzer
    {
        public NoDefaultConstructorAnalyzer(int unused) { _ = unused; }
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray<DiagnosticDescriptor>.Empty;
    }
}
