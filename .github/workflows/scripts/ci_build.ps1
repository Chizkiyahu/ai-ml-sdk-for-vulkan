#!/usr/bin/env pwsh

# SPDX-FileCopyrightText: Copyright 2025 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Usage
if ($args.Count -gt 0 -and ($args[0] -eq "-h" -or $args[0] -eq "--help")) {
    $scriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { "ci_build.ps1" }
    Write-Host "Usage: $scriptName"
    Write-Host
    Write-Host "Environment:"
    Write-Host "  MANIFEST_URL   (optional)  default: https://github.com/arm/ai-ml-sdk-manifest.git"
    Write-Host "  REPO_DIR       (optional)  default: ./sdk"
    Write-Host "  INSTALL_DIR    (optional)  default: ./install"
    Write-Host "  CHANGED_REPO   (optional)  manifest project name to pin and resync"
    Write-Host "  CHANGED_SHA    (optional)  commit SHA to pin CHANGED_REPO to (required if CHANGED_REPO is set)"
    Write-Host "  OVERRIDES      (optional)  JSON object: { ""org/repo"": ""40-char-sha"", ... }"
    exit 0
}

# Environment defaults
$ManifestUrl = if ($env:MANIFEST_URL) { $env:MANIFEST_URL } else { "https://github.com/arm/ai-ml-sdk-manifest.git" }
$RepoDir     = if ($env:REPO_DIR)     { $env:REPO_DIR }     else { Join-Path (Get-Location) "sdk" }
$InstallDir  = if ($env:INSTALL_DIR)  { $env:INSTALL_DIR }  else { Join-Path (Get-Location) "install" }
$ChangedRepo = $env:CHANGED_REPO
$ChangedSha  = $env:CHANGED_SHA
$Overrides   = $env:OVERRIDES

Write-Host "Using manifest URL: $ManifestUrl"
Write-Host "Using repo directory: $RepoDir"
Write-Host "Using install directory: $InstallDir"
Write-Host "find CHANGED_REPO: $ChangedRepo"
Write-Host "find CHANGED_SHA: $ChangedSha"
Write-Host "find OVERRIDES: $Overrides"

$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

Write-Host "CPUs: $cores"
Write-Host "Windows detected, disabling repo verification"
Write-Host "Windows detected, skipping Emulation Layer and Scenario Runner tests"

# Locate git-repo Python script
if (-not $env:GITHUB_WORKSPACE) {
    Write-Error "GITHUB_WORKSPACE is not set. ci_build.ps1 expects to run inside GitHub Actions."
}
$RepoScriptPath = Join-Path $env:GITHUB_WORKSPACE "git-repo\repo"
if (-not (Test-Path $RepoScriptPath)) {
    Write-Error "git-repo script not found at $RepoScriptPath. Clone https://gerrit.googlesource.com/git-repo there before running."
}

mkdir $RepoDir -Force
mkdir $InstallDir -Force

$RepoDir    = (Resolve-Path $RepoDir).Path
$InstallDir = (Resolve-Path $InstallDir).Path

Push-Location $RepoDir
try {
    python $RepoScriptPath init --no-repo-verify -u $ManifestUrl
    python $RepoScriptPath sync --no-repo-verify --no-clone-bundle -j $cores

    # Local manifests
    New-Item -ItemType Directory -Path ".repo/local_manifests" -Force | Out-Null

    if ($Overrides) {
        # OVERRIDES: JSON object: { "org/repo": "sha", ... }
        $manifestArgs = @($RepoScriptPath, "manifest", "-r")
        $manifestText = python @manifestArgs
        $manifestXml = $manifestText -join "`n"

        $overridesObj = $Overrides | ConvertFrom-Json

        foreach ($prop in $overridesObj.PSObject.Properties) {
            $name = $prop.Name
            $revision = [string]$prop.Value

            $xpath = "//project[@name='$name']/@path"
            $projectPath = $manifestXml | xml.exe sel -t -v $xpath

            if (-not $projectPath) {
                Write-Error "ERROR: project path for $name not found in manifest"
            }

            $overrideFile = ".repo/local_manifests/override.xml"
            if (Test-Path $overrideFile) {
                Remove-Item $overrideFile -Force
            }

            $overrideContent = @"
<manifest>
  <project name="$name" revision="$revision" remote="github"/>
</manifest>
"@
            $overrideContent | Set-Content -Path $overrideFile -Encoding UTF8

            Write-Host "Syncing $name ($projectPath)"
            python $RepoScriptPath sync -j $cores --force-sync $projectPath

        }
    }
    elseif ($ChangedRepo) {
        if (-not $ChangedSha) {
            Write-Error "CHANGED_REPO is set but CHANGED_SHA is empty"
        }

        $manifestArgs = @($RepoScriptPath, "manifest", "-r")
        $manifestText = python @manifestArgs
        $manifestXml = $manifestText -join "`n"

        $xpath = "//project[@name='$ChangedRepo']/@path"
        $projectPath = $manifestXml | xml.exe sel -t -v $xpath

        if (-not $projectPath) {
            Write-Error "Could not find project path for $ChangedRepo in manifest"
        }
        Write-Host "Changed project path: $projectPath"

        $overrideFile = ".repo/local_manifests/override.xml"
        $overrideContent = @"
<manifest>
  <project name="$ChangedRepo" revision="$ChangedSha" remote="github"/>
</manifest>
"@
        $overrideContent | Set-Content -Path $overrideFile -Encoding UTF8
        python $RepoScriptPath sync -j $cores --force-sync $projectPath

    }

    $env:VK_LAYER_PATH = Join-Path $InstallDir "share/vulkan/explicit_layer.d"
    $env:VK_INSTANCE_LAYERS = "VK_LAYER_ML_Graph_Emulation:VK_LAYER_ML_Tensor_Emulation"
    $env:LD_LIBRARY_PATH = Join-Path $InstallDir "lib"

    Write-Host "Build VGF-Lib"
    python "./sw/vgf-lib/scripts/build.py" -j $cores --test

    Write-Host "Build Model Converter"
    python "./sw/model-converter/scripts/build.py" -j $cores --test

    Write-Host "Build Emulation Layer"
    python "./sw/emulation-layer/scripts/build.py" -j $cores --test

    Write-Host "Build Scenario Runner"
    python "./sw/scenario-runner/scripts/setup.py" -j $cores --test

    Write-Host "Build SDK Root"
    python "./scripts/build.py" -j $cores
}
finally {
    Pop-Location
}
