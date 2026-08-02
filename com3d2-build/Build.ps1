$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Root '_work'
$Out = Join-Path $Root '_artifact'
Remove-Item -Recurse -Force $Work,$Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Work,$Out | Out-Null

$MaintainedCommit = 'b3ba70ceab633fa152be57dd2b6a1746d934b9bb'
$LegacyTag = 'v2.0.0.0'
$PackRevision = 'R3'

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

function Remove-JsonSidecar([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $text = [regex]::Replace($text, '(?m)^using Newtonsoft\.Json;\r?\n', '')
    $pattern = '(?ms)^\s*StreamWriter writer = new StreamWriter\(Path\.Combine\(ExportFolder, ExportName \+ "\.json"\)\);\s*string jsonInfo = JsonConvert\.SerializeObject\(materialInfo, Formatting\.Indented\);\s*writer\.Write\(jsonInfo\);\s*writer\.Close\(\);\s*'
    $patched = [regex]::Replace($text, $pattern, '')
    if ($patched -eq $text) { throw "Expected Newtonsoft JSON output block was not found in $Path" }
    [System.IO.File]::WriteAllText($Path, $patched, (New-Object System.Text.UTF8Encoding($false)))
}

$PmxAPath = Join-Path $Src 'COM3D2.ModelExportMMD\PmxExporter.cs'
$PmxBPath = Join-Path $Src 'COM3D2.ModelExportMMD\PmxBuilder.cs'
Remove-JsonSidecar $PmxAPath
Remove-JsonSidecar $PmxBPath

# Correct the second model-comment assignment to CommentE without embedding
# any non-ASCII text in this Windows PowerShell 5.1 script.
$pmxBText = Get-Content -LiteralPath $PmxBPath -Raw
$metadataPattern = '(?s)(pmxModelInfo\.Comment\s*=\s*".*?";\s*)pmxModelInfo\.Comment\s*=\s*("my maid";)'
$metadataReplacement = '${1}pmxModelInfo.CommentE = ${2}'
$patchedPmxBText = [regex]::Replace($pmxBText, $metadataPattern, $metadataReplacement, 1)
if ($patchedPmxBText -eq $pmxBText) { throw 'MMD B metadata correction gate failed.' }
[System.IO.File]::WriteAllText($PmxBPath, $patchedPmxBText, (New-Object System.Text.UTF8Encoding($false)))

$ProjectPath = Join-Path $Src 'COM3D2.ModelExportMMD.csproj'
[xml]$project = Get-Content -LiteralPath $ProjectPath
$ns = New-Object System.Xml.XmlNamespaceManager($project.NameTable)
$ns.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')

foreach ($ref in @($project.SelectNodes('//m:Reference',$ns))) {
    if ($ref.Include -like 'BepInEx*' -or $ref.Include -like 'Newtonsoft.Json*') {
        [void]$ref.ParentNode.RemoveChild($ref)
    }
}

$itemGroup = $project.SelectSingleNode('//m:ItemGroup[m:Reference]',$ns)
function Add-Reference([string]$name,[string]$hint) {
    $query = "//m:Reference[starts-with(@Include,'" + $name + "')]"
    $existing = $project.SelectSingleNode($query,$ns)
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

$PmxASource = Get-Content -LiteralPath $PmxAPath -Raw
$pmxAMarkers = @(
    'for (Transform bone = skinnedMesh.bones[i]; bone != null; bone = bone.parent)',
    'pmxVertex.UpdateDeformType()',
    'pmxBone.To_Offset',
    'if (!vertexIndexMap.ContainsKey(parentName))'
)
foreach ($marker in $pmxAMarkers) {
    if (-not $PmxASource.Contains($marker)) { throw "MMD A source gate failed: $marker" }
}

$PmxBSource = Get-Content -LiteralPath $PmxBPath -Raw
$pmxBMarkers = @(
    'SetBoneParents();',
    'BoneParentSort();',
    'ChangeBoneNames();',
    'AddBone();',
    'ChangeBoneInfo();',
    'AddPhysics();',
    'FindBone("Bip01 L Foot")',
    'FindBone("Bip01 R Foot")',
    'pmxModelInfo.CommentE = "my maid";'
)
foreach ($marker in $pmxBMarkers) {
    if (-not $PmxBSource.Contains($marker)) { throw "MMD B source gate failed: $marker" }
}

foreach ($sourceText in @($PmxASource,$PmxBSource)) {
    if ($sourceText.Contains('JsonConvert') -or $sourceText.Contains('Newtonsoft.Json')) { throw 'JSON dependency removal gate failed.' }
}

$PluginSource = Get-Content -LiteralPath (Join-Path $Src 'COM3D2.ModelExportMMD.Plugin\ModelExportPlugin.cs') -Raw
if ($PluginSource.Contains('BepInEx')) { throw 'Sybaris plugin source still contains BepInEx.' }
if (-not $PluginSource.Contains('public class ModelExportPlugin : PluginBase')) { throw 'PluginBase inheritance gate failed.' }
if (-not $PluginSource.Contains('[PluginFilter("COM3D2x64")]')) { throw 'COM3D2x64 filter gate failed.' }
if (-not $PluginSource.Contains('ExportClass = ModelExportEventArgs.ExporterClass.PmxB')) { throw 'MMD B default gate failed.' }
if (-not $PluginSource.Contains('exporter = new PmxBuilder();')) { throw 'MMD B routing gate failed.' }

Write-Host 'Building against COM3D2/Sybaris v2 dependency baseline...'
msbuild (Join-Path $Src 'COM3D2.ModelExportMMD.sln') /m /t:Rebuild /p:Configuration=Release /p:Platform="Any CPU" /p:DebugSymbols=false /p:DebugType=None /p:LangVersion=latest /verbosity:minimal

$Built = Join-Path $Src 'bin\Release\COM3D2.ModelExportMMD.Plugin.dll'
if (-not (Test-Path -LiteralPath $Built)) { throw 'Build output DLL was not produced.' }
if ((Get-Item -LiteralPath $Built).Length -lt 180000) { throw 'Built DLL is unexpectedly small.' }

$resolve = [ResolveEventHandler] {
    param($sender,$eventArgs)
    $simple = (New-Object System.Reflection.AssemblyName($eventArgs.Name)).Name + '.dll'
    foreach ($folder in @($Deps,(Join-Path $Src 'bin\Release'))) {
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
    if ($referenceNames -contains 'Newtonsoft.Json') { throw 'Built DLL still references Newtonsoft.Json.' }
    if ($referenceNames -notcontains 'Assembly-CSharp') { throw 'Built DLL does not reference Assembly-CSharp.' }
    if ($referenceNames -notcontains 'UnityEngine') { throw 'Built DLL does not reference UnityEngine.' }

    $typeNames = @($assembly.GetTypes() | ForEach-Object { $_.FullName })
    foreach ($requiredType in @(
        'COM3D2.ModelExportMMD.Plugin.ModelExportPlugin',
        'COM3D2.ModelExportMMD.PmxExporter',
        'COM3D2.ModelExportMMD.PmxBuilder'
    )) {
        if ($typeNames -notcontains $requiredType) { throw "Built DLL is missing type: $requiredType" }
    }
}
finally {
    [AppDomain]::CurrentDomain.remove_ReflectionOnlyAssemblyResolve($resolve)
}

Copy-Item -LiteralPath $Built -Destination (Join-Path $Out 'COM3D2.ModelExportMMD.Plugin.dll')

$manifest = @(
    "PACK=COM3D2_SYBARIS_MODEL_EXPORT_$PackRevision",
    "MAINTAINED_COMMIT=$MaintainedCommit",
    "SYBARIS_BASELINE=$LegacyTag",
    'TARGET_LOADER=Sybaris/UnityInjector',
    'DEFAULT_EXPORTER=MMD_B_JAPANESE',
    'MMD_A=ENGLISH_BONE_NAMES',
    'MMD_B=JAPANESE_STANDARD_BONES_AND_IK',
    'BEPINEX_REFERENCE=ABSENT',
    'NEWTONSOFT_REFERENCE=ABSENT',
    'MMD_B_EXPORTER=ENABLED',
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
COM3D2 Sybaris ModelExportMMD R3

BUILD-ONLY artifact. Do not install until promoted after validation.
Target loader: Sybaris / UnityInjector
Default format: MMD B with standard MMD bone names and IK.
MMD A remains available for English/raw armature export.
External JSON dependency: removed.
'@ | Set-Content -LiteralPath (Join-Path $Out 'README_BUILD_ONLY.txt') -Encoding UTF8

$ZipPath = Join-Path $Root 'COM3D2_SYBARIS_MODEL_EXPORT_R3_BUILD.zip'
Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $ZipPath -Force
Write-Host 'BUILD_PIPELINE=PASS'
