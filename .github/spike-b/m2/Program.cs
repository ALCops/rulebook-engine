// Method 2: console app, AssemblyLoadContext + AssemblyDependencyResolver. Usage: m2 <toolsDir> [<alcopsDir>] <out.json>
using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json;

var sw = System.Diagnostics.Stopwatch.StartNew();
string toolsDir = Path.GetFullPath(args[0]);
string alcopsDir = args.Length > 2 ? Path.GetFullPath(args[1]) : null;
string outFile = args[^1];
Console.WriteLine($"runtime {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
var alc = new AnalyzerContext(new[] { alcopsDir, toolsDir }.Where(d => d != null).ToArray());
var ca = alc.LoadFromAssemblyPath(Path.Combine(toolsDir, "Microsoft.Dynamics.Nav.CodeAnalysis.dll"));
Console.WriteLine($"loaded {ca.FullName}");
var baseType = ca.GetType("Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer", true);
var rows = new List<Dictionary<string, object>>();
var ec = ca.GetType("Microsoft.Dynamics.Nav.CodeAnalysis.ErrorCode", true);
foreach (var n in Enum.GetNames(ec))
{
    int v = Convert.ToInt32(Enum.Parse(ec, n));
    if (v < 100) continue;
    string sev = n.StartsWith("WRN_") ? "Warning" : n.StartsWith("INF_") ? "Info" : n.StartsWith("HDN_") ? "Hidden" : "Error";
    if (sev == "Error") continue;
    rows.Add(new() { ["id"] = $"AL{v:0000}", ["assembly"] = "Microsoft.Dynamics.Nav.CodeAnalysis", ["defaultSeverity"] = sev, ["enabledByDefault"] = true });
}
Console.WriteLine($"compiler: {rows.Count} configurable ids");
var dlls = Directory.GetFiles(toolsDir, "Microsoft.Dynamics.Nav.*Cop.dll").ToList();
if (alcopsDir != null) dlls.AddRange(Directory.GetFiles(alcopsDir, "ALCops.*.dll"));
int fail = 0;
foreach (var dll in dlls.OrderBy(d => d))
{
    var asm = alc.LoadFromAssemblyPath(dll);
    Type[] types;
    try { types = asm.GetTypes(); }
    catch (ReflectionTypeLoadException e) { types = e.Types.Where(t => t != null).ToArray(); Console.WriteLine($"  {Path.GetFileName(dll)}: ReflectionTypeLoadException, {e.Types.Length - types.Length} types not loaded ({e.LoaderExceptions[0]?.Message})"); }
    int n0 = rows.Count, nt = 0;
    foreach (var t in types.Where(t => t.IsClass && !t.IsAbstract && baseType.IsAssignableFrom(t) && t.GetConstructor(Type.EmptyTypes) != null))
    {
        nt++;
        try
        {
            var inst = Activator.CreateInstance(t);
            var sd = (System.Collections.IEnumerable)baseType.GetProperty("SupportedDiagnostics").GetValue(inst);
            foreach (var d in sd)
            {
                var dt = d.GetType();
                object P(string p) => dt.GetProperty(p).GetValue(d);
                rows.Add(new() { ["id"] = P("Id"), ["assembly"] = asm.GetName().Name, ["defaultSeverity"] = P("DefaultSeverity").ToString(), ["enabledByDefault"] = P("IsEnabledByDefault"), ["title"] = P("Title")?.ToString(), ["helpLinkUri"] = P("HelpLinkUri"), ["category"] = P("Category") });
            }
        }
        catch (Exception e) { fail++; Console.WriteLine($"  ! {t.FullName}: {e.GetBaseException().Message}"); }
    }
    Console.WriteLine($"{Path.GetFileName(dll)}: {nt} analyzer types, {rows.Count - n0} descriptors");
}
var unique = rows.GroupBy(r => (string)r["id"]).OrderBy(g => g.Key).Select(g => g.First()).ToList();
File.WriteAllText(outFile, JsonSerializer.Serialize(unique, new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine($"unique ids: {unique.Count}; instantiation failures: {fail}; elapsed {sw.Elapsed.TotalSeconds:n1} s");

class AnalyzerContext : AssemblyLoadContext
{
    readonly string[] dirs; readonly List<AssemblyDependencyResolver> resolvers = new();
    public AnalyzerContext(string[] dirs) : base("analyzers")
    {
        this.dirs = dirs;
        foreach (var d in dirs) foreach (var f in Directory.GetFiles(d, "*.deps.json"))
        {
            var dll = Path.ChangeExtension(Path.ChangeExtension(f, null), ".dll");
            if (File.Exists(dll)) resolvers.Add(new AssemblyDependencyResolver(dll));
        }
    }
    protected override Assembly Load(AssemblyName name)
    {
        foreach (var r in resolvers) { var p = r.ResolveAssemblyToPath(name); if (p != null && File.Exists(p)) return LoadFromAssemblyPath(p); }
        foreach (var d in dirs) { var p = Path.Combine(d, name.Name + ".dll"); if (File.Exists(p)) return LoadFromAssemblyPath(p); }
        return null; // framework assemblies from the default context
    }
}
