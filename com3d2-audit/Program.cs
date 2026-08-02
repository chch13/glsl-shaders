using System.Collections.Immutable;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text;

internal static class Program
{
    private static readonly string[] AuditedDependencies =
    {
        "Assembly-CSharp",
        "UnityEngine",
        "ExIni",
    };

    private static int Main(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine("Usage: Com3d2MetadataAudit <candidate.dll> <old-working-plugin.dll> <dependency-directory> <report.txt>");
            return 2;
        }

        string candidatePath = Path.GetFullPath(args[0]);
        string oldPluginPath = Path.GetFullPath(args[1]);
        string dependencyDirectory = Path.GetFullPath(args[2]);
        string reportPath = Path.GetFullPath(args[3]);

        var report = new List<string>
        {
            "COM3D2_SYBARIS_METADATA_COMPATIBILITY_AUDIT",
            $"CANDIDATE={candidatePath}",
            $"OLD_WORKING_PLUGIN={oldPluginPath}",
            $"DEPENDENCY_DIRECTORY={dependencyDirectory}",
        };

        try
        {
            RequireFile(candidatePath);
            RequireFile(oldPluginPath);
            if (!Directory.Exists(dependencyDirectory))
            {
                throw new DirectoryNotFoundException(dependencyDirectory);
            }

            using var candidate = MetadataImage.Open(candidatePath);
            using var oldPlugin = MetadataImage.Open(oldPluginPath);

            report.Add($"CANDIDATE_SHA256={Sha256(candidatePath)}");
            report.Add($"OLD_WORKING_PLUGIN_SHA256={Sha256(oldPluginPath)}");
            report.Add($"CANDIDATE_ASSEMBLY={candidate.AssemblyIdentity}");
            report.Add($"OLD_WORKING_ASSEMBLY={oldPlugin.AssemblyIdentity}");

            string[] candidateReferences = candidate.GetAssemblyReferences().OrderBy(value => value, StringComparer.Ordinal).ToArray();
            string[] oldReferences = oldPlugin.GetAssemblyReferences().OrderBy(value => value, StringComparer.Ordinal).ToArray();
            bool assemblyReferencesIdentical = candidateReferences.SequenceEqual(oldReferences, StringComparer.Ordinal);
            report.Add($"CANDIDATE_ASSEMBLY_REFS={string.Join(';', candidateReferences)}");
            report.Add($"OLD_WORKING_ASSEMBLY_REFS={string.Join(';', oldReferences)}");
            report.Add($"ASSEMBLY_REFERENCE_LIST_IDENTICAL={assemblyReferencesIdentical}");

            bool forbiddenReferencesAbsent = true;
            foreach (string forbidden in new[] { "BepInEx", "Newtonsoft.Json" })
            {
                bool present = candidateReferences.Any(value => value.StartsWith(forbidden + ":", StringComparison.Ordinal));
                report.Add($"{forbidden.ToUpperInvariant().Replace('.', '_')}_REFERENCE_PRESENT={present}");
                forbiddenReferencesAbsent &= !present;
            }

            bool dependencyAuditPass = true;
            foreach (string dependencyName in AuditedDependencies)
            {
                string dependencyPath = ResolveDependency(dependencyDirectory, dependencyName);
                using var dependency = MetadataImage.Open(dependencyPath);
                DependencyAudit result = AuditDependency(candidate, dependencyName, dependency);
                string key = dependencyName.ToUpperInvariant().Replace('-', '_');
                report.Add($"{key}_FILE={dependencyPath}");
                report.Add($"{key}_SHA256={Sha256(dependencyPath)}");
                report.Add($"{key}_EXTERNAL_TYPEREF_COUNT={result.ReferencedTypeCount}");
                report.Add($"{key}_EXTERNAL_MEMBERREF_COUNT={result.ReferencedMemberCount}");
                report.Add($"{key}_MISSING_TYPE_COUNT={result.MissingTypes.Count}");
                report.Add($"{key}_MISSING_MEMBER_COUNT={result.MissingMembers.Count}");
                foreach (string item in result.MissingTypes)
                {
                    report.Add($"MISSING_TYPE={dependencyName}|{item}");
                }
                foreach (string item in result.MissingMembers)
                {
                    report.Add($"MISSING_MEMBER={dependencyName}|{item}");
                }
                dependencyAuditPass &= result.MissingTypes.Count == 0 && result.MissingMembers.Count == 0;
            }

            HashSet<string> candidateUnityInjectorMembers = candidate.GetExternalMemberReferences("UnityInjector");
            HashSet<string> oldUnityInjectorMembers = oldPlugin.GetExternalMemberReferences("UnityInjector");
            bool unityInjectorMemberSetIdentical = candidateUnityInjectorMembers.SetEquals(oldUnityInjectorMembers);
            report.Add($"UNITYINJECTOR_MEMBERREF_SET_IDENTICAL={unityInjectorMemberSetIdentical}");
            report.Add($"UNITYINJECTOR_CANDIDATE_MEMBERREF_COUNT={candidateUnityInjectorMembers.Count}");
            report.Add($"UNITYINJECTOR_OLD_MEMBERREF_COUNT={oldUnityInjectorMembers.Count}");
            foreach (string member in candidateUnityInjectorMembers.Except(oldUnityInjectorMembers, StringComparer.Ordinal).OrderBy(value => value, StringComparer.Ordinal))
            {
                report.Add($"UNITYINJECTOR_MEMBER_ONLY_IN_CANDIDATE={member}");
            }
            foreach (string member in oldUnityInjectorMembers.Except(candidateUnityInjectorMembers, StringComparer.Ordinal).OrderBy(value => value, StringComparer.Ordinal))
            {
                report.Add($"UNITYINJECTOR_MEMBER_MISSING_FROM_CANDIDATE={member}");
            }

            string? pluginBase = candidate.GetBaseType("COM3D2.ModelExportMMD.Plugin.ModelExportPlugin");
            bool pluginBasePass = string.Equals(pluginBase, "UnityInjector.PluginBase", StringComparison.Ordinal);
            bool pmxExporterPresent = candidate.HasType("COM3D2.ModelExportMMD.PmxExporter");
            bool pmxBuilderPresent = candidate.HasType("COM3D2.ModelExportMMD.PmxBuilder");
            report.Add($"PLUGIN_BASE_TYPE={pluginBase ?? "<missing>"}");
            report.Add($"PLUGIN_BASE_TYPE_PASS={pluginBasePass}");
            report.Add($"PMX_EXPORTER_TYPE_PRESENT={pmxExporterPresent}");
            report.Add($"PMX_BUILDER_TYPE_PRESENT={pmxBuilderPresent}");

            bool pass = assemblyReferencesIdentical
                && forbiddenReferencesAbsent
                && dependencyAuditPass
                && unityInjectorMemberSetIdentical
                && pluginBasePass
                && pmxExporterPresent
                && pmxBuilderPresent;

            report.Add($"RESULT={(pass ? "PASS" : "FAIL")}");
            Directory.CreateDirectory(Path.GetDirectoryName(reportPath) ?? Directory.GetCurrentDirectory());
            File.WriteAllLines(reportPath, report, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            foreach (string line in report)
            {
                Console.WriteLine(line);
            }
            return pass ? 0 : 1;
        }
        catch (Exception exception)
        {
            report.Add("RESULT=ERROR");
            report.Add($"ERROR_TYPE={exception.GetType().FullName}");
            report.Add($"ERROR_MESSAGE={exception.Message.Replace(Environment.NewLine, " ")}");
            Directory.CreateDirectory(Path.GetDirectoryName(reportPath) ?? Directory.GetCurrentDirectory());
            File.WriteAllLines(reportPath, report, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            foreach (string line in report)
            {
                Console.Error.WriteLine(line);
            }
            return 3;
        }
    }

    private static void RequireFile(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("Required file not found.", path);
        }
    }

    private static string ResolveDependency(string directory, string assemblyName)
    {
        string exact = Path.Combine(directory, assemblyName + ".dll");
        if (File.Exists(exact))
        {
            return exact;
        }

        string? match = Directory.EnumerateFiles(directory, "*.dll", SearchOption.TopDirectoryOnly)
            .FirstOrDefault(path =>
            {
                try
                {
                    using var image = MetadataImage.Open(path);
                    return string.Equals(image.AssemblyName, assemblyName, StringComparison.OrdinalIgnoreCase);
                }
                catch
                {
                    return false;
                }
            });

        return match ?? throw new FileNotFoundException($"Dependency assembly not found: {assemblyName}");
    }

    private static DependencyAudit AuditDependency(MetadataImage candidate, string dependencyName, MetadataImage dependency)
    {
        HashSet<string> referencedTypes = candidate.GetExternalTypeReferences(dependencyName);
        HashSet<string> referencedMembers = candidate.GetExternalMemberReferences(dependencyName);
        HashSet<string> availableTypes = dependency.GetDefinedTypes();
        HashSet<string> availableMembers = dependency.GetDefinedMembers();

        var missingTypes = referencedTypes
            .Where(type => !availableTypes.Contains(type))
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToList();
        var missingMembers = referencedMembers
            .Where(member => !availableMembers.Contains(member))
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToList();

        return new DependencyAudit(referencedTypes.Count, referencedMembers.Count, missingTypes, missingMembers);
    }

    private static string Sha256(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private sealed record DependencyAudit(
        int ReferencedTypeCount,
        int ReferencedMemberCount,
        List<string> MissingTypes,
        List<string> MissingMembers);
}

internal sealed class MetadataImage : IDisposable
{
    private readonly FileStream _stream;
    private readonly PEReader _peReader;
    private readonly MetadataReader _reader;
    private readonly CanonicalTypeProvider _typeProvider;

    private MetadataImage(string path, FileStream stream, PEReader peReader, MetadataReader reader)
    {
        Path = path;
        _stream = stream;
        _peReader = peReader;
        _reader = reader;
        _typeProvider = new CanonicalTypeProvider();
    }

    public string Path { get; }

    public string AssemblyName
    {
        get
        {
            AssemblyDefinition definition = _reader.GetAssemblyDefinition();
            return _reader.GetString(definition.Name);
        }
    }

    public string AssemblyIdentity
    {
        get
        {
            AssemblyDefinition definition = _reader.GetAssemblyDefinition();
            return $"{_reader.GetString(definition.Name)}:{definition.Version}";
        }
    }

    public static MetadataImage Open(string path)
    {
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            var peReader = new PEReader(stream, PEStreamOptions.LeaveOpen);
            if (!peReader.HasMetadata)
            {
                peReader.Dispose();
                throw new BadImageFormatException("PE file has no managed metadata.", path);
            }
            MetadataReader reader = peReader.GetMetadataReader();
            if (!reader.IsAssembly)
            {
                peReader.Dispose();
                throw new BadImageFormatException("Managed metadata is not an assembly.", path);
            }
            return new MetadataImage(path, stream, peReader, reader);
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    public IEnumerable<string> GetAssemblyReferences()
    {
        foreach (AssemblyReferenceHandle handle in _reader.AssemblyReferences)
        {
            AssemblyReference reference = _reader.GetAssemblyReference(handle);
            yield return $"{_reader.GetString(reference.Name)}:{reference.Version}";
        }
    }

    public HashSet<string> GetExternalTypeReferences(string assemblyName)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (TypeReferenceHandle handle in _reader.TypeReferences)
        {
            if (string.Equals(GetTypeReferenceAssembly(handle), assemblyName, StringComparison.OrdinalIgnoreCase))
            {
                result.Add(GetTypeReferenceFullName(handle));
            }
        }
        return result;
    }

    public HashSet<string> GetExternalMemberReferences(string assemblyName)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (MemberReferenceHandle handle in _reader.MemberReferences)
        {
            MemberReference member = _reader.GetMemberReference(handle);
            if (member.Parent.Kind != HandleKind.TypeReference)
            {
                continue;
            }

            var typeHandle = (TypeReferenceHandle)member.Parent;
            if (!string.Equals(GetTypeReferenceAssembly(typeHandle), assemblyName, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            string owner = GetTypeReferenceFullName(typeHandle);
            result.Add(GetMemberReferenceKey(owner, member));
        }
        return result;
    }

    public HashSet<string> GetDefinedTypes()
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (TypeDefinitionHandle handle in _reader.TypeDefinitions)
        {
            result.Add(GetTypeDefinitionFullName(handle));
        }
        return result;
    }

    public HashSet<string> GetDefinedMembers()
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (TypeDefinitionHandle typeHandle in _reader.TypeDefinitions)
        {
            TypeDefinition type = _reader.GetTypeDefinition(typeHandle);
            string owner = GetTypeDefinitionFullName(typeHandle);
            var context = new GenericContext();

            foreach (MethodDefinitionHandle methodHandle in type.GetMethods())
            {
                MethodDefinition method = _reader.GetMethodDefinition(methodHandle);
                MethodSignature<string> signature = method.DecodeSignature(_typeProvider, context);
                result.Add(MethodKey(owner, _reader.GetString(method.Name), signature));
            }

            foreach (FieldDefinitionHandle fieldHandle in type.GetFields())
            {
                FieldDefinition field = _reader.GetFieldDefinition(fieldHandle);
                string fieldType = field.DecodeSignature(_typeProvider, context);
                result.Add(FieldKey(owner, _reader.GetString(field.Name), fieldType));
            }
        }
        return result;
    }

    public bool HasType(string fullName)
    {
        return _reader.TypeDefinitions.Any(handle => string.Equals(GetTypeDefinitionFullName(handle), fullName, StringComparison.Ordinal));
    }

    public string? GetBaseType(string fullName)
    {
        foreach (TypeDefinitionHandle handle in _reader.TypeDefinitions)
        {
            if (!string.Equals(GetTypeDefinitionFullName(handle), fullName, StringComparison.Ordinal))
            {
                continue;
            }

            EntityHandle baseType = _reader.GetTypeDefinition(handle).BaseType;
            return baseType.Kind switch
            {
                HandleKind.TypeDefinition => GetTypeDefinitionFullName((TypeDefinitionHandle)baseType),
                HandleKind.TypeReference => GetTypeReferenceFullName((TypeReferenceHandle)baseType),
                HandleKind.TypeSpecification => _reader.GetTypeSpecification((TypeSpecificationHandle)baseType)
                    .DecodeSignature(_typeProvider, new GenericContext()),
                _ => null,
            };
        }
        return null;
    }

    private string GetMemberReferenceKey(string owner, MemberReference member)
    {
        string name = _reader.GetString(member.Name);
        return member.GetKind() switch
        {
            MemberReferenceKind.Method => MethodKey(owner, name, member.DecodeMethodSignature(_typeProvider, new GenericContext())),
            MemberReferenceKind.Field => FieldKey(owner, name, member.DecodeFieldSignature(_typeProvider, new GenericContext())),
            _ => $"U|{owner}|{name}",
        };
    }

    private static string MethodKey(string owner, string name, MethodSignature<string> signature)
    {
        string instance = signature.Header.IsInstance ? "I" : "S";
        return $"M|{owner}|{name}|{instance}|G{signature.GenericParameterCount}|R:{signature.ReturnType}|P:{string.Join(',', signature.ParameterTypes)}";
    }

    private static string FieldKey(string owner, string name, string fieldType)
    {
        return $"F|{owner}|{name}|{fieldType}";
    }

    internal string GetTypeDefinitionFullName(TypeDefinitionHandle handle)
    {
        TypeDefinition definition = _reader.GetTypeDefinition(handle);
        string name = _reader.GetString(definition.Name);
        TypeDefinitionHandle declaring = definition.GetDeclaringType();
        if (!declaring.IsNil)
        {
            return GetTypeDefinitionFullName(declaring) + "+" + name;
        }

        string ns = _reader.GetString(definition.Namespace);
        return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
    }

    internal string GetTypeReferenceFullName(TypeReferenceHandle handle)
    {
        TypeReference reference = _reader.GetTypeReference(handle);
        string name = _reader.GetString(reference.Name);
        if (reference.ResolutionScope.Kind == HandleKind.TypeReference)
        {
            return GetTypeReferenceFullName((TypeReferenceHandle)reference.ResolutionScope) + "+" + name;
        }

        string ns = _reader.GetString(reference.Namespace);
        return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
    }

    private string? GetTypeReferenceAssembly(TypeReferenceHandle handle)
    {
        TypeReference reference = _reader.GetTypeReference(handle);
        EntityHandle scope = reference.ResolutionScope;
        while (scope.Kind == HandleKind.TypeReference)
        {
            scope = _reader.GetTypeReference((TypeReferenceHandle)scope).ResolutionScope;
        }

        if (scope.Kind == HandleKind.AssemblyReference)
        {
            AssemblyReference assembly = _reader.GetAssemblyReference((AssemblyReferenceHandle)scope);
            return _reader.GetString(assembly.Name);
        }

        return scope.Kind == HandleKind.ModuleDefinition ? AssemblyName : null;
    }

    public void Dispose()
    {
        _peReader.Dispose();
        _stream.Dispose();
    }

    private sealed class CanonicalTypeProvider : ISignatureTypeProvider<string, GenericContext>
    {
        public string GetArrayType(string elementType, ArrayShape shape)
        {
            return elementType + "[" + new string(',', Math.Max(0, shape.Rank - 1)) + "]";
        }

        public string GetByReferenceType(string elementType) => elementType + "&";

        public string GetFunctionPointerType(MethodSignature<string> signature)
        {
            return "fnptr(" + signature.ReturnType + "(" + string.Join(',', signature.ParameterTypes) + "))";
        }

        public string GetGenericInstantiation(string genericType, ImmutableArray<string> typeArguments)
        {
            return genericType + "<" + string.Join(',', typeArguments) + ">";
        }

        public string GetGenericMethodParameter(GenericContext genericContext, int index) => "!!" + index;

        public string GetGenericTypeParameter(GenericContext genericContext, int index) => "!" + index;

        public string GetModifiedType(string modifierType, string unmodifiedType, bool isRequired)
        {
            return unmodifiedType + (isRequired ? " modreq(" : " modopt(") + modifierType + ")";
        }

        public string GetPinnedType(string elementType) => elementType + " pinned";

        public string GetPointerType(string elementType) => elementType + "*";

        public string GetPrimitiveType(PrimitiveTypeCode typeCode) => typeCode.ToString();

        public string GetSZArrayType(string elementType) => elementType + "[]";

        public string GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte rawTypeKind)
        {
            TypeDefinition definition = reader.GetTypeDefinition(handle);
            string name = reader.GetString(definition.Name);
            TypeDefinitionHandle declaring = definition.GetDeclaringType();
            if (!declaring.IsNil)
            {
                return GetTypeFromDefinition(reader, declaring, rawTypeKind) + "+" + name;
            }
            string ns = reader.GetString(definition.Namespace);
            return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
        }

        public string GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte rawTypeKind)
        {
            TypeReference reference = reader.GetTypeReference(handle);
            string name = reader.GetString(reference.Name);
            if (reference.ResolutionScope.Kind == HandleKind.TypeReference)
            {
                return GetTypeFromReference(reader, (TypeReferenceHandle)reference.ResolutionScope, rawTypeKind) + "+" + name;
            }
            string ns = reader.GetString(reference.Namespace);
            return string.IsNullOrEmpty(ns) ? name : ns + "." + name;
        }

        public string GetTypeFromSpecification(MetadataReader reader, GenericContext genericContext, TypeSpecificationHandle handle, byte rawTypeKind)
        {
            return reader.GetTypeSpecification(handle).DecodeSignature(this, genericContext);
        }
    }
}

internal sealed class GenericContext
{
}
