param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Replace-ExactlyOnce {
    param(
        [string]$InputText,
        [string]$Pattern,
        [string]$Replacement,
        [string]$Label
    )

    $regex = New-Object System.Text.RegularExpressions.Regex(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    $matches = $regex.Matches($InputText)
    if ($matches.Count -ne 1) {
        throw "$Label patch expected exactly one match, found $($matches.Count)."
    }
    return $regex.Replace($InputText, $Replacement, 1)
}

$text = Get-Content -LiteralPath $Path -Raw

$text = Replace-ExactlyOnce $text `
    'private Mesh mesh3;' `
    @'
private Mesh mesh3;
        private readonly List<int> meshVertexStarts = new List<int>();
        private readonly List<int> meshVertexCounts = new List<int>();
'@ `
    'mesh range field'

$text = Replace-ExactlyOnce $text `
    'public void CreateMeshList\(SkinnedMeshRenderer meshRender\)\s*\{' `
    @'
public void CreateMeshList(SkinnedMeshRenderer meshRender)
        {
            int exportedVertexStart = pmxFile.VertexList.Count;
'@ `
    'CreateMeshList entry'

$text = Replace-ExactlyOnce $text `
    'pmxFile\.VertexList\.Add\(pmxVertex\);\s*\}\s*\}\s*(?=private UnityEngine\.Vector3 TransToParent)' `
    @'
pmxFile.VertexList.Add(pmxVertex);
            }
            meshVertexStarts.Add(exportedVertexStart);
            meshVertexCounts.Add(mesh.vertexCount);
        }

        
'@ `
    'CreateMeshList range capture'

$text = Replace-ExactlyOnce $text `
    'public void SetParent\(Transform\[\] tlist\)\s*\{.*?\n\s*\}\s*\n\s*public void SetBoneParents' `
    @'
public void SetParent(Transform[] tlist)
        {
            for (int i = 0; i < pmxFile.BoneList.Count; i++)
            {
                pmxFile.BoneList[i].Name = pmxFile.BoneList[i].Name.Replace("_SCL_", "");
            }
            for (int i = 0; i < bones2.Count; i++)
            {
                for (int j = 0; j < bones2[i].names.Count; j++)
                {
                    if (bones2[i].names[j] != null)
                    {
                        bones2[i].names[j] = bones2[i].names[j].Replace("_SCL_", "");
                    }
                }
            }

            if (boneList.Count != pmxFile.BoneList.Count)
            {
                throw new InvalidOperationException("Bone source and PMX bone counts differ before hierarchy mapping.");
            }

            for (int i = 0; i < boneList.Count; i++)
            {
                Transform parent = boneList[i].parent;
                while (parent != null)
                {
                    string parentName = parent.name.Replace("_SCL_", "");
                    int parentIndex = FindBoneIndex(parentName);
                    if (parentIndex >= 0 && parentIndex != i)
                    {
                        pmxFile.BoneList[i].Parent = parentIndex;
                        break;
                    }
                    parent = parent.parent;
                }
            }
        }

        public void SetBoneParents
'@ `
    'SetParent hierarchy'

$text = Replace-ExactlyOnce $text `
    'private void CreateVers\(List<SkinnedMeshRenderer> skinnedMeshes\)\s*\{.*?\n\s*\}\s*\n\s*public void Export' `
    @'
private void SetBone(List<SkinnedMeshRenderer> skinnedMeshes)
        {
            if (meshVertexStarts.Count != skinnedMeshes.Count ||
                meshVertexCounts.Count != skinnedMeshes.Count ||
                bones2.Count != skinnedMeshes.Count)
            {
                throw new InvalidOperationException("Mesh-to-bone mapping tables do not match the exported mesh count.");
            }

            for (int meshIndex = 0; meshIndex < skinnedMeshes.Count; meshIndex++)
            {
                int start = meshVertexStarts[meshIndex];
                int count = meshVertexCounts[meshIndex];
                List<string> localBoneNames = bones2[meshIndex].names;

                if (count != skinnedMeshes[meshIndex].sharedMesh.vertexCount)
                {
                    throw new InvalidOperationException("Exported vertex count differs from the source mesh vertex count.");
                }

                for (int vertexIndex = start; vertexIndex < start + count; vertexIndex++)
                {
                    PmxVertex vertex = pmxFile.VertexList[vertexIndex];
                    for (int weightIndex = 0; weightIndex < vertex.Weight.Length; weightIndex++)
                    {
                        int localBoneIndex = vertex.Weight[weightIndex].Bone;
                        if (localBoneIndex < 0 || localBoneIndex >= localBoneNames.Count)
                        {
                            throw new IndexOutOfRangeException("A vertex references a bone outside its source mesh bone table.");
                        }

                        string localBoneName = localBoneNames[localBoneIndex];
                        if (string.IsNullOrEmpty(localBoneName))
                        {
                            if (vertex.Weight[weightIndex].Value == 0f)
                            {
                                vertex.Weight[weightIndex].Bone = 0;
                                continue;
                            }
                            throw new InvalidOperationException("A non-zero vertex weight references an unnamed source bone.");
                        }

                        int mappedBoneIndex = FindBoneIndex(localBoneName);
                        if (mappedBoneIndex < 0)
                        {
                            throw new InvalidOperationException("Unable to map source bone into the combined PMX bone table: " + localBoneName);
                        }
                        vertex.Weight[weightIndex].Bone = mappedBoneIndex;
                    }
                    vertex.UpdateDeformType();
                }
            }
        }

        public void Export
'@ `
    'SetBone exact mesh ranges'

$requiredMarkers = @(
    'meshVertexStarts.Add(exportedVertexStart);',
    'while (parent != null)',
    'Mesh-to-bone mapping tables do not match the exported mesh count.',
    'vertex.UpdateDeformType();'
)
foreach ($marker in $requiredMarkers) {
    if (-not $text.Contains($marker)) {
        throw "Patched MMD B source is missing marker: $marker"
    }
}

$forbiddenMarkers = @(
    'new Vers[skinnedMeshes.Count - 1]',
    'vers[i].v[j].Weight[k].Bone <= 100',
    'tlist[j].parent != null || FindBone(tlist[j].parent.name) != null'
)
foreach ($marker in $forbiddenMarkers) {
    if ($text.Contains($marker)) {
        throw "Patched MMD B source still contains unsafe marker: $marker"
    }
}

[System.IO.File]::WriteAllText(
    $Path,
    $text,
    (New-Object System.Text.UTF8Encoding($false))
)
