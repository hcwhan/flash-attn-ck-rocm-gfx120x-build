# Derive expected_wheel_pattern from VERSION.lock.json toolchain fields.
function Get-Cxx11AbiWheelTagFromLock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [string]$PythonExe = ""
    )

    if ($null -ne $Lock.PSObject.Properties['cxx11_abi'] -and $null -ne $Lock.cxx11_abi) {
        $raw = $Lock.cxx11_abi
        if ($raw -eq $true -or [string]$raw -eq 'true' -or [string]$raw -eq '1') {
            return "cxx11abiTRUE"
        }
        return "cxx11abiFALSE"
    }

    if ($PythonExe) {
        $abiLine = & $PythonExe -c "import torch; print(torch._C._GLIBCXX_USE_CXX11_ABI)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $abiLine) {
            return if ($abiLine.Trim() -eq "True") { "cxx11abiTRUE" } else { "cxx11abiFALSE" }
        }
    }

    return "cxx11abiTRUE"
}

function Get-ExpectedWheelPatternFromLock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [string]$PythonExe = ""
    )

    $pytorch = [string]$Lock.pytorch
    $hip = [string]$Lock.hip
    $python = [string]$Lock.python

    if (-not $pytorch) { throw "VERSION.lock.json pytorch is missing" }
    if (-not $hip) { throw "VERSION.lock.json hip is missing" }
    if (-not $python) { throw "VERSION.lock.json python is missing" }

    if ($pytorch -notmatch '^(\d+)\.(\d+)\.\d+\+rocm(\d+)\.(\d+)\.\d+(?<local>[a-zA-Z0-9.]*)?$') {
        throw "VERSION.lock.json pytorch must look like 2.12.0+rocm7.14.0 or 2.12.0+rocm7.14.0a20260519, got: $pytorch"
    }
    $torchMajor = $Matches[1]
    $torchMinor = $Matches[2]
    $ptRocmMajor = $Matches[3]
    $ptRocmMinor = $Matches[4]

    $hipParts = $hip -split '\.'
    if ($hipParts.Count -lt 2) {
        throw "VERSION.lock.json hip must look like 7.14.0, got: $hip"
    }
    $hipMajor = $hipParts[0]
    $hipMinor = $hipParts[1]

    if ($hipMajor -ne $ptRocmMajor -or $hipMinor -ne $ptRocmMinor) {
        throw "VERSION.lock.json hip ($hip) does not match rocm version in pytorch ($pytorch)"
    }

    $pyParts = $python -split '\.'
    if ($pyParts.Count -lt 2) {
        throw "VERSION.lock.json python must look like 3.12, got: $python"
    }
    $pyTag = "cp$($pyParts[0])$($pyParts[1])"

    $rocmTag = "$hipMajor$hipMinor"
    $torchTag = "$torchMajor$torchMinor"
    $abiTag = Get-Cxx11AbiWheelTagFromLock -Lock $Lock -PythonExe $PythonExe

    return "flash_attn-*+rocm${rocmTag}torch${torchTag}${abiTag}-${pyTag}-${pyTag}-win_amd64.whl"
}

function Assert-ExpectedWheelPatternConsistent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [string]$PythonExe = ""
    )

    $declared = [string]$Lock.expected_wheel_pattern
    if (-not $declared) {
        throw "VERSION.lock.json expected_wheel_pattern is missing"
    }

    $computed = Get-ExpectedWheelPatternFromLock -Lock $Lock -PythonExe $PythonExe
    if ($declared -ne $computed) {
        throw @(
            "VERSION.lock.json expected_wheel_pattern does not match toolchain fields.",
            "  declared: $declared",
            "  expected: $computed",
            "Update expected_wheel_pattern or bump pytorch/hip/python/cxx11_abi together."
        ) -join "`n"
    }

    return $computed
}
