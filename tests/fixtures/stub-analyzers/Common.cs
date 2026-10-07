// Stub of ALCops.Common.dll: CM0001 at Info and disabled by default.
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace ALCops.Common
{
    public sealed class ConfigurationAnalyzer : DiagnosticAnalyzer
    {
        private static readonly DiagnosticDescriptor CM0001 = new DiagnosticDescriptor("CM0001", "The ALCops configuration file could not be fully loaded", "Configuration", DiagnosticSeverity.Info, false, "https://alcops.dev/docs/analyzers/common/cm0001/");
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(CM0001);
    }
}
