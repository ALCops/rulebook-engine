// A cop with one advertised id, for the cops the suites only need present (the minimum expected set of
// Rulebook.Extract). Build-StubPackage.ps1 replaces the tokens: __NAMESPACE__, __ID__, __SEVERITY__, __ENABLED__,
// __TITLE__ and __LINK__ (a C# string literal or null).
using System.Collections.Immutable;
using Microsoft.Dynamics.Nav.CodeAnalysis;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace __NAMESPACE__
{
    public sealed class OnlyRuleAnalyzer : DiagnosticAnalyzer
    {
        private static readonly DiagnosticDescriptor Rule = new DiagnosticDescriptor("__ID__", "__TITLE__", "Stub", DiagnosticSeverity.__SEVERITY__, __ENABLED__, __LINK__);
        public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics => ImmutableArray.Create(Rule);
    }
}
