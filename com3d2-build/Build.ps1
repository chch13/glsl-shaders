$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Root '_work'
$Out = Join-Path $Root '_artifact'
Remove-Item -Recurse -Force $Work,$Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Work,$Out | Out-Null

$MaintainedCommit = 'b3ba70ceab633fa152be57dd2b6a1746d934b9bb'
$LegacyTag = 'v2.0.0.0'

Write-Host 'Cloning maintained exporter source...'
git clone --quiet https://github.com/rintrint/COM3D2.ModelExportMMD.git (Join-Path $Work 'src')
pushd (Join-Path $Work 'src')
git checkout --quiet $MaintainedCommit
popd

Write-Host 'Cloning Sybaris v2 dependency baseline...'
git clone --quiet --branch $LegacyTag --depth 1 https://github.com/suiginsoft/COM3D2.ModelExportMMD.git (Join-Path $Work 'v2')

$Src = Join-Path $Work 'src'
$V2 = Join-Path $Work 'v2'
$Deps = Join-Path $Src 'Dependencies'
New-Item -ItemType Directory -Force -Path $Deps | Out-Null

foreach ($name in @('Assembly-CSharp.dll','UnityEngine.dll','ExIni.dll','UnityInjector.dll')) {
    $source = Join-Path (Join-Path $V2 'Dependencies') $name
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing v2 dependency: $name" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $Deps $name) -Force
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SybarisModelExportPlugin.cs') -Destination (Join-Path $Src 'COM3D2.ModelExportMMD.Plugin\ModelExportPlugin.cs') -Force

$ProjectPath = Join-Path $Src 'COM3D2.ModelExportMMD.csproj'
[xml]$project = Get-Content -LiteralPath $ProjectPath
$ns = New-Object System.Xml.XmlNamespaceManager($project.NameTable)
$ns.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')

foreach ($ref in @($project.SelectNodes('//m:Reference',$ns))) {
    if ($ref.Include -like 'BepInEx*') {
        [void]$ref.ParentNode.RemoveChild($ref)
    }
}

$itemGroup = $project.SelectSingleNode('//m:ItemGroup[m:Reference]',$ns)
function Add-Reference([string]$name,[string]$hint) {
    $existing = $project.SelectSingleNode("//m:Reference[starts-with(@Include,'$name')]",$ns)
    if ($null -ne $existing) { return }
    $ref = $project.CreateElement('Reference',$ns.LookupNamespace('m'))
    $ref.SetAttribute('Include',$name)
    $hintNode = $project.CreateElement('HintPath',$ns.LookupNamespace('m'))
    $hintNode.InnerText = $hint
    [void]$ref.AppendChild($hintNode)
    $privateNode = $project.CreateElement('Private',$ns.LookupNamespace('m'))
    $privateNode.InnerText = 'False'
    [void]$ref.AppendChild($privateNode)
    [void]$itemGroup.AppendChild($ref)
}
Add-Reference 'ExIni' 'Dependencies\ExIni.dll'
Add-Reference 'UnityInjector' 'Dependencies\UnityInjector.dll'
$project.Save($ProjectPath)

$PmxSource = Get-Content -LiteralPath (Join-Path $Src 'COM3D2.ModelExportMMD\PmxExporter.cs') -Raw
$requiredSourceMarkers = @(
    'for (Transform bone = skinnedMesh.bones[i]; bone != null; bone = bone.parent)',
    'pmxVertex.UpdateDeformType()',
    'pmxBone.To_Offset',
    'if (!vertexIndexMap.ContainsKey(parentName))'
)
foreach ($marker in $requiredSourceMarkers) {
    if (-not $PmxSource.Contains($marker)) { throw "Maintained source gate failed: $marker" }
}

$PluginSource = Get-Content -LiteralPath (Join-Path $Src 'COM3D2.ModelExportMMD.Plugin\ModelExportPlugin.cs') -Raw
if ($PluginSource.Contains('BepInEx')) { throw 'Sybaris plugin source still contains BepInEx.' }
if (-not $PluginSource.Contains('public class ModelExportPlugin : PluginBase')) { throw 'PluginBase inheritance gate failed.' }
if (-not $PluginSource.Contains('[PluginFilter("COM3D2x64")]')) { throw 'COM3D2x64 filter gate failed.' }

Write-Host 'Restoring NuGet packages...'
nuget restore (Join-Path $Src 'COM3D2.ModelExportMMD.sln') -PackagesDirectory (Join-Path $Src 'packages') -NonInteractive

Write-Host 'Building against COM3D2/Sybaris v2 dependency baseline...'
msbuild (Join-Path $Src 'COM3D2.ModelExportMMD.sln') /m /t:Rebuild /p:Configuration=Release /p:Platform="Any CPU" /p:DebugSymbols=false /p:DebugType=None /p:LangVersion=latest /verbosity:minimal

$Built = Join-Path $Src 'bin\Release\COM3D2.ModelExportMMD.Plugin.dll'
if (-not (Test-Path -LiteralPath $Built)) { throw 'Build output DLL was not produced.' }
if ((Get-Item -LiteralPath $Built).Length -lt 100000) { throw 'Built DLL is unexpectedly small.' }

$resolve = [ResolveEventHandler] {
    param($sender,$eventArgs)
    $simple = (New-Object System.Reflection.AssemblyName($eventArgs.Name)).Name + '.dll'
    foreach ($folder in @($Deps,(Join-Path $Src 'bin\Release'),(Join-Path $Src 'packages\Newtonsoft.Json.12.0.3\lib\net35'))) {
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
    if ($referenceNames -notcontains 'UnityInjector') { throw 'Built DLL does not reference UnityInjector.' }
    if ($referenceNames -contains 'BepInEx') { throw 'Built DLL still references BepInEx.' }
    if ($referenceNames -notcontains 'Assembly-CSharp') { throw 'Built DLL does not reference Assembly-CSharp.' }
    if ($referenceNames -notcontains 'UnityEngine') { throw 'Built DLL does not reference UnityEngine.' }
}
finally {
    [AppDomain]::CurrentDomain.remove_ReflectionOnlyAssemblyResolve($resolve)
}

Copy-Item -LiteralPath $Built -Destination (Join-Path $Out 'COM3D2.ModelExportMMD.Plugin.dll')
$Newtonsoft = Join-Path $Src 'bin\Release\Newtonsoft.Json.dll'
if (Test-Path -LiteralPath $Newtonsoft) {
    Copy-Item -LiteralPath $Newtonsoft -Destination (Join-Path $Out 'Newtonsoft.Json.dll')
}

$manifest = @(
    'PACK=COM3D2_SYBARIS_MODEL_EXPORT_R1',
    "MAINTAINED_COMMIT=$MaintainedCommit",
    "SYBARIS_BASELINE=$LegacyTag",
    'TARGET_LOADER=Sybaris/UnityInjector',
    'BEPINEX_REFERENCE=ABSENT',
    'BUILD=PASS',
    'SOURCE_GATES=PASS',
    'ASSEMBLY_REFERENCE_GATES=PASS'
)
foreach ($file in Get-ChildItem -LiteralPath $Out -File) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $manifest += ("SHA256_{0}={1}" -f $file.Name,$hash)
}
$manifest | Set-Content -LiteralPath (Join-Path $Out 'MANIFEST.txt') -Encoding UTF8

@'
COM3D2 Sybaris ModelExportMMD R1

BUILD-ONLY artifact. Do not install until it is promoted after validation.
Target loader: Sybaris / UnityInjector
Maintained exporter commit: b3ba70ceab633fa152be57dd2b6a1746d934b9bb
Sybaris compatibility baseline: official v2.0.0.0 dependencies
'@ | Set-Content -LiteralPath (Join-Path $Out 'README_BUILD_ONLY.txt') -Encoding UTF8

$ZipPath = Join-Path $Root 'COM3D2_SYBARIS_MODEL_EXPORT_R1_BUILD.zip'
Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $ZipPath -Force
Write-Host 'BUILD_PIPELINE=PASS'
