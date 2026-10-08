// Built for -Fault ThrowingConstructor: an analyzer whose parameterless constructor throws.
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace Microsoft.Dynamics.Nav.ThrowingCop
{
    public sealed class ThrowingAnalyzer : DiagnosticAnalyzer
    {
        public ThrowingAnalyzer() { throw new System.InvalidOperationException("stub constructor failure"); }
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray<DiagnosticDescriptor>.Empty;
    }
}
