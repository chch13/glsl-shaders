$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$BaseBuild = Join-Path $PSScriptRoot 'Build.ps1'
$PatchPmxB = Join-Path $PSScriptRoot 'Patch-PmxB.ps1'
$Work = Join-Path $Root '_work'
$Src = Join-Path $Work 'src'
$Deps = Join-Path $Src 'Dependencies'
$Out = Join-Path $Root '_artifact_r4'
$R4Bin = Join-Path $Src 'bin\R4'
$R4Obj = Join-Path $Src 'obj\R4'

& $BaseBuild
if ($LASTEXITCODE -ne 0) {
    throw "R3 baseline build failed with exit code $LASTEXITCODE."
}

$PmxBPath = Join-Path $Src 'COM3D2.ModelExportMMD\PmxBuilder.cs'
& $PatchPmxB -Path $PmxBPath
if ($LASTEXITCODE -ne 0) {
    throw "MMD B hardening patch failed with exit code $LASTEXITCODE."
}

$patchedSource = Get-Content -LiteralPath $PmxBPath -Raw
$requiredMarkers = @(
    'meshVertexStarts.Add(exportedVertexStart);',
    'while (parent != null)',
    'Mesh-to-bone mapping tables do not match the exported mesh count.',
    'vertex.UpdateDeformType();'
)
foreach ($marker in $requiredMarkers) {
    if (-not $patchedSource.Contains($marker)) {
        throw "R4 source gate failed: $marker"
    }
}

$forbiddenMarkers = @(
    'new Vers[skinnedMeshes.Count - 1]',
    'vers[i].v[j].Weight[k].Bone <= 100',
    'tlist[j].parent != null || FindBone(tlist[j].parent.name) != null'
)
foreach ($marker in $forbiddenMarkers) {
    if ($patchedSource.Contains($marker)) {
        throw "R4 source still contains unsafe logic: $marker"
    }
}

Remove-Item -Recurse -Force $R4Bin,$R4Obj -ErrorAction SilentlyContinue
Write-Host 'Rebuilding hardened MMD B exporter into isolated output...'
msbuild (Join-Path $Src 'COM3D2.ModelExportMMD.sln') /m /t:Rebuild /p:Configuration=Release /p:Platform="Any CPU" /p:OutputPath="bin\R4\" /p:IntermediateOutputPath="obj\R4\" /p:DebugSymbols=false /p:DebugType=None /p:LangVersion=latest /verbosity:minimal
if ($LASTEXITCODE -ne 0) {
    throw "R4 rebuild failed with exit code $LASTEXITCODE."
}

$Built = Join-Path $R4Bin 'COM3D2.ModelExportMMD.Plugin.dll'
if (-not (Test-Path -LiteralPath $Built)) {
    throw 'R4 build output DLL was not produced.'
}
if ((Get-Item -LiteralPath $Built).Length -lt 180000) {
    throw 'R4 built DLL is unexpectedly small.'
}

$resolve = [ResolveEventHandler] {
    param($sender,$eventArgs)
    $simple = (New-Object System.Reflection.AssemblyName($eventArgs.Name)).Name + '.dll'
    foreach ($folder in @($Deps,$R4Bin)) {
        $candidate = Join-Path $folder $simple
        if (Test-Path -LiteralPath $candidate) {
            return [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($candidate)
        }
    }
    return $null
}
[AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve($resolve)
try {
    $assembly = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($Built)
    $referenceNames = @($assembly.GetReferencedAssemblies() | ForEach-Object { $_.Name })
    if ($referenceNames -notcontains 'UnityInjector') { throw 'R4 DLL does not reference UnityInjector.' }
    if ($referenceNames -contains 'BepInEx') { throw 'R4 DLL still references BepInEx.' }
    if ($referenceNames -contains 'Newtonsoft.Json') { throw 'R4 DLL still references Newtonsoft.Json.' }
    if ($referenceNames -notcontains 'Assembly-CSharp') { throw 'R4 DLL does not reference Assembly-CSharp.' }
    if ($referenceNames -notcontains 'UnityEngine') { throw 'R4 DLL does not reference UnityEngine.' }

    $typeNames = @($assembly.GetTypes() | ForEach-Object { $_.FullName })
    foreach ($requiredType in @(
        'COM3D2.ModelExportMMD.Plugin.ModelExportPlugin',
        'COM3D2.ModelExportMMD.PmxExporter',
        'COM3D2.ModelExportMMD.PmxBuilder'
    )) {
        if ($typeNames -notcontains $requiredType) {
            throw "R4 DLL is missing type: $requiredType"
        }
    }
}
finally {
    [AppDomain]::CurrentDomain.remove_ReflectionOnlyAssemblyResolve($resolve)
}

Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Copy-Item -LiteralPath $Built -Destination (Join-Path $Out 'COM3D2.ModelExportMMD.Plugin.dll')

$dllHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Built).Hash.ToLowerInvariant()
$manifest = @(
    'PACK=COM3D2_SYBARIS_MODEL_EXPORT_R4',
    'TARGET_LOADER=Sybaris/UnityInjector',
    'DEFAULT_EXPORTER=MMD_B_JAPANESE',
    'MMD_A=ENGLISH_RAW_ARMATURE',
    'MMD_B=JAPANESE_STANDARD_BONES_AND_IK',
    'MMD_B_VERTEX_RANGE_MAPPING=EXACT_PER_MESH',
    'MMD_B_LOCAL_BONE_INDEX_LIMIT=REMOVED',
    'MMD_B_PARENT_MAPPING=ANCESTOR_WALK',
    'BEPINEX_REFERENCE=ABSENT',
    'NEWTONSOFT_REFERENCE=ABSENT',
    'WINDOWS_BUILD=PASS',
    'SOURCE_GATES=PASS',
    'ASSEMBLY_REFERENCE_GATES=PASS',
    "SHA256_COM3D2.ModelExportMMD.Plugin.dll=$dllHash"
)
$manifest | Set-Content -LiteralPath (Join-Path $Out 'MANIFEST.txt') -Encoding UTF8

@'
COM3D2 Sybaris ModelExportMMD R4

BUILD-ONLY artifact. Do not install until promoted after all validation gates.

R4 hardens the Japanese MMD B exporter:
- maps every mesh by its exact exported vertex range
- maps every local bone index without the old <=100 shortcut
- walks actual transform ancestors for parent assignment
- updates each vertex deform type after bone remapping
- fails closed on missing or out-of-range bone mappings
'@ | Set-Content -LiteralPath (Join-Path $Out 'README_BUILD_ONLY.txt') -Encoding UTF8

$ZipPath = Join-Path $Root 'COM3D2_SYBARIS_MODEL_EXPORT_R4_BUILD.zip'
Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $ZipPath -Force
Write-Host 'R4_BUILD_PIPELINE=PASS'
