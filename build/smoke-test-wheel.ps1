param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir
)

$ErrorActionPreference = "Stop"

$whl = Get-ChildItem (Join-Path $DistDir "*.whl") | Select-Object -First 1
if (-not $whl) {
    throw "No wheel produced in $DistDir"
}
python -m pip install $whl.FullName
python -c "from flash_attn import flash_attn_func; import flash_attn_2_cuda; print('OK', flash_attn_2_cuda.__file__); print([x for x in dir(flash_attn_2_cuda) if not x.startswith('_')])"
