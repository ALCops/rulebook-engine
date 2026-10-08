// Built for -Fault MissingDependency: a cop whose type derives from Stub.Missing.Base, an assembly the package does not
// ship, so loading its types fails.
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace Microsoft.Dynamics.Nav.BrokenCop
{
    public sealed class Derived : Stub.Missing.Base
    {
    }

    public sealed class BrokenAnalyzer : DiagnosticAnalyzer
    {
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray<DiagnosticDescriptor>.Empty;
    }
}
