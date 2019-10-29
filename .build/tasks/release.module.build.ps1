param(
    # Base directory of all output (default to 'output')
    [string]$OutputDirectory = (property OutputDirectory (Join-Path $BuildRoot 'output')),

    $ChangelogPath = (property ChangelogPath 'CHANGELOG.md'),

    $ReleaseNotesPath = (property ReleaseNotesPath (Join-Path $OutputDirectory 'ReleaseNotes.md')),

    [string]
    $ProjectName = (property ProjectName $(
            #Find the module manifest to deduce the Project Name
            (Get-ChildItem $BuildRoot\*\*.psd1 | Where-Object {
                    ($_.Directory.Name -match 'source|src' -or $_.Directory.Name -eq $_.BaseName) -and
                    $(try {
                            Test-ModuleManifest $_.FullName -ErrorAction Stop
                        }
                        catch {
                            $false
                        }) }
            ).BaseName
        )
    ),

    [string]
    $ModuleVersion = (property ModuleVersion $(
            try {
                (gitversion | ConvertFrom-Json -ErrorAction Stop).InformationalVersion
            }
            catch {
                Write-Verbose "Error attempting to use GitVersion $($_)"
                ''
            }
        )),

    [string]
    # retrieves from Environment variable
    $GitHubToken = (property GitHubToken ''),

    [string]
    $GalleryApiToken = (property GalleryApiToken ''),

    [string]
    $NuGetPublishSource = (property NuGetPublishSource 'https://www.powershellgallery.com/'),

    $PSModuleFeed = (property PSModuleFeed 'PSGallery')
)

# Synopsis: Create ReleaseNotes from changelog and update the Changelog for release
task Create_changelog_release_output {
    if (!(Split-Path -isAbsolute $OutputDirectory)) {
        $OutputDirectory = Join-path $BuildRoot $OutputDirectory
    }

    if(!(Split-Path -isAbsolute $ReleaseNotesPath)) {
        $ReleaseNotesPath = Join-path $OutputDirectory $ReleaseNotesPath
    }

    $ChangeLogOutputPath = Join-path $OutputDirectory 'CHANGELOG.md'


    if ([String]::IsNullOrEmpty($ModuleVersion)) {
        $ModuleInfo = Import-PowerShellDataFile "$OutputDirectory/$ProjectName/*/$ProjectName.psd1" -ErrorAction Stop
        if ($PreReleaseTag = $ModuleInfo.PrivateData.PSData.Prerelease) {
            $ModuleVersion = $ModuleInfo.ModuleVersion + "-" + $PreReleaseTag
        }
        else {
            $ModuleVersion = $ModuleInfo.ModuleVersion
        }
    }
    else {
        # Remove metadata from ModuleVersion
        $ModuleVersion, $BuildMetadata = $ModuleVersion -split '\+', 2
        # Remove Prerelease tag from ModuleVersionFolder
        $ModuleVersionFolder, $PreReleaseTag = $ModuleVersion -split '\-', 2
    }

    # Parse the Changelog and extract unreleased
    try {
        Import-Module ChangelogManagement -ErrorAction Stop

        # Update the source changelog file
        Update-Changelog -Path $ChangeLogPath -OutputPath $ChangeLogOutputPath -ErrorAction Stop -ReleaseVersion $ModuleVersion -LinkMode none

        # Create a ReleaseNotes from the Updated changelog
        ConvertFrom-Changelog -Path $ChangeLogOutputPath -Format Release -NoHeader -OutputPath $ReleaseNotesPath -ErrorAction Stop
    }
    catch {
        if (-not ($ReleaseNotes = (Get-Content -raw $ReleaseNotesPath -ErrorAction SilentlyContinue))) {
            $ReleaseNotes = Get-Content -raw $ChangeLogOutputPath -ErrorAction SilentlyContinue
        }
    }
}

task publish_nupkg_to_gallery -if ((Get-Command nuget -ErrorAction SilentlyContinue) -and $GalleryApiToken) {
    if ([String]::IsNullOrEmpty($ModuleVersion)) {
        $ModuleInfo = Import-PowerShellDataFile "$OutputDirectory/$ProjectName/*/$ProjectName.psd1" -ErrorAction Stop
        if ($PreReleaseTag = $ModuleInfo.PrivateData.PSData.Prerelease) {
            $ModuleVersion = $ModuleInfo.ModuleVersion + "-" + $PreReleaseTag
        }
        else {
            $ModuleVersion = $ModuleInfo.ModuleVersion
        }
    }
    else {
        # Remove metadata from ModuleVersion
        $ModuleVersion, $BuildMetadata = $ModuleVersion -split '\+', 2
        # Remove Prerelease tag from ModuleVersionFolder
        $ModuleVersionFolder, $PreReleaseTag = $ModuleVersion -split '\-', 2
    }

    # find Module's nupkg
    $PackageToRelease = Get-ChildItem (Join-Path $OutputDirectory "$ProjectName.$PSModuleVersion.nupkg")
    $ReleaseTag = "v$PSModuleVersion"

    Write-Build DarkGray "About to release $PackageToRelease"
    $response = &nuget push $PackageToRelease -source $nugetPublishSource -ApiKey $GalleryApiToken
    Write-Build Green $response
}

# Synopsis: Packaging the module by Publishing to output folder (incl dependencies)
task package_module_nupkg {

    # Force registering the output repository mapping to the Project's output path
    $null = Unregister-PSRepository -Name output -ErrorAction SilentlyContinue
    $RepositoryParams = @{
        Name            = 'output'
        SourceLocation  = $OutputDirectory
        PublishLocation = $OutputDirectory
        ErrorAction     = 'Stop'
    }

    $null = Register-PSRepository @RepositoryParams

    # Cleaning up existing packaged module
    if ($ModuleToRemove = Get-ChildItem (Join-Path $OutputDirectory "$ProjectName.*.nupkg")) {
        Write-Build DarkGray "  Remove existing $ProjectName package"
        remove-item -force -Path $ModuleToRemove -ErrorAction Stop
    }

    # find Module manifest
    $BuiltModuleManifest = (Get-ChildItem (Join-Path $OutputDirectory $ProjectName) -Depth 2 -Filter "$ProjectName.psd1").FullName
    Write-Build DarkGray "  Built module's Manifest found at $BuiltModuleManifest"

    # load module manifest
    $ModuleInfo = Import-PowerShellDataFile -Path $BuiltModuleManifest

    # Publish dependencies (from environment) so we can publish the built module
    foreach ($module in $ModuleInfo.RequiredModules) {
        if(!(Find-Module -repository output -Name $Module -ErrorAction SilentlyContinue)) {
            # Replace the module by first (path & version) resolved in PSModulePath
            $module = Get-Module -ListAvailable $module | Select-Object -First 1
            if ($Prerelease = $module.PrivateData.PSData.Prerelease) {
                $Prerelease = "-" + $Prerelease
            }
            Write-Build Yellow ("  Packaging Required Module {0} v{1}{2}" -f $Module.Name,$Module.Version.ToString(),$Prerelease)
            Publish-Module -Repository output -ErrorAction SilentlyContinue -Path $module.ModuleBase
        }
    }

    $PublishModuleParams = @{
        Path       = (Join-Path $OutputDirectory $ProjectName)
        Repository = 'output'
        Force      = $true
        ErrorAction = 'Stop'
    }
    Publish-Module @PublishModuleParams
    Write-Build Green "`n  Packaged $ProjectName NuGet package `n"
    Write-Build DarkGray "  Cleaning up"

    $null = Unregister-PSRepository -Name output -ErrorAction SilentlyContinue
}

task publish_module_to_gallery -if ((!(Get-Command nuget -ErrorAction SilentlyContinue)) -and $GalleryApiToken) {
    if (!(Split-Path $OutputDirectory -IsAbsolute)) {
        $OutputDirectory = Join-Path $BuildRoot $OutputDirectory
    }

    if(!(Split-Path -isAbsolute $ReleaseNotesPath)) {
        $ReleaseNotesPath = Join-path $OutputDirectory $ReleaseNotesPath
    }

    # Retrieving ReleaseNotes or defaulting to Updated ChangeLog
    if (-not ($ReleaseNotes = (Get-Content -raw $ReleaseNotesPath -ErrorAction SilentlyContinue))) {
        $ReleaseNotes = Get-Content -raw $ChangeLogPath -ErrorAction SilentlyContinue
    }

    $null = Test-ModuleManifest "$OutputDirectory/$ProjectName/*/$ProjectName.psd1" -ErrorAction Stop
    $ModulePath = Join-Path $OutputDirectory $ProjectName

    Write-Build DarkGray "`nAbout to release $ModulePath"

    $PublishModuleParams = @{
        Path         = $ModulePath
        NuGetApiKey  = $GalleryApiToken
        Repository   = $PSModuleFeed
        ErrorAction  = 'Stop'
        releaseNotes = $ReleaseNotes
    }

    Publish-Module @PublishModuleParams

    Write-Build Green "Package Published to PSGallery"

}