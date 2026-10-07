// Stub of ALCops.TestAutomationCop.dll: TA0001 with the link as the real package ships it (capital C, a 404).
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace ALCops.TestAutomationCop
{
    public sealed class TestMethodAnalyzer : DiagnosticAnalyzer
    {
        private static readonly DiagnosticDescriptor TA0001 = new DiagnosticDescriptor("TA0001", "Test codeunits need a test method", "Testing", DiagnosticSeverity.Warning, true, "https://alcops.dev/docs/analyzers/testautomationCop/ta0001/");
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(TA0001);
    }
}
