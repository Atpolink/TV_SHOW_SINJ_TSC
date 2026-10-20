# Data_All_AIP_Watcher.ps1

$TargetRoot = "D:\Database_Server_Spare\Data_All_AIP"
$FileNames = @("anr.lst", "mnr.lst")
$PollSeconds = 30

# กำหนด IP ของเครื่อง AIP
# ใส่ IP ของ AIP103-AIP110 ให้ครบเมื่อทราบ
$AipSources = [ordered]@{
    "AIP101" = "\\192.168.10.47\mpdv\AIP2\spool"
    "AIP102" = "\\192.168.10.44\mpdv\AIP2\spool"
    "AIP103" = "\\192.168.10.46\mpdv\AIP2\spool"
    "AIP104" = "\\192.168.10.45\mpdv\AIP2\spool"
    "AIP105" = "\\192.168.10.241\mpdv\AIP2\spool"
    "AIP106" = "\\192.168.10.240\mpdv\AIP2\spool"
    "AIP109" = "\\192.168.10.243\mpdv\AIP2\spool"
    "AIP110" = "\\192.168.10.245\mpdv\AIP2\spool"
}

# จำสถานะไฟล์ล่าสุด เพื่อไม่ต้องคัดลอกซ้ำถ้าไม่มีการเปลี่ยนแปลง
$script:LastState = @{}

function Get-CurrentShift {
    $time = (Get-Date).TimeOfDay

    if ($time -ge [TimeSpan]::Parse("08:00") -and
        $time -lt [TimeSpan]::Parse("18:10")) {
        return "Shift 1"
    }
    elseif ($time -ge [TimeSpan]::Parse("18:10") -and
            $time -lt [TimeSpan]::Parse("20:00")) {
        return "Shift 2"
    }
    elseif ($time -ge [TimeSpan]::Parse("20:00") -and
            $time -lt [TimeSpan]::Parse("22:00")) {
        return "Shift 3"
    }
    else {
        return "Shift 4"
    }
}

function Copy-SourceFile {
    param(
        [string]$SourceFile,
        [string]$TargetFile
    )

    $tempFile = "$TargetFile.tmp"

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            # อ่านสถานะต้นทางก่อนคัดลอก
            $before = Get-Item -LiteralPath $SourceFile -ErrorAction Stop
            $lengthBefore = $before.Length
            $writeBefore = $before.LastWriteTimeUtc.Ticks

            # คัดลอกไปไฟล์ชั่วคราวก่อน
            [System.IO.File]::Copy(
                $SourceFile,
                $tempFile,
                $true
            )

            # ตรวจสอบว่าต้นทางเปลี่ยนระหว่างคัดลอกหรือไม่
            $after = Get-Item -LiteralPath $SourceFile -ErrorAction Stop

            if ($after.Length -ne $lengthBefore -or
                $after.LastWriteTimeUtc.Ticks -ne $writeBefore) {

                Remove-Item -LiteralPath $tempFile `
                    -Force -ErrorAction SilentlyContinue

                Start-Sleep -Seconds 1
                continue
            }

            # แทนที่ไฟล์เดิมเมื่อคัดลอกสำเร็จ
            if (Test-Path -LiteralPath $TargetFile) {
                [System.IO.File]::Replace(
                    $tempFile,
                    $TargetFile,
                    $null
                )
            }
            else {
                [System.IO.File]::Move(
                    $tempFile,
                    $TargetFile
                )
            }

            return [PSCustomObject]@{
                Success = $true
                Length = $lengthBefore
                LastWriteTicks = $writeBefore
            }
        }
        catch {
            Remove-Item -LiteralPath $tempFile `
                -Force -ErrorAction SilentlyContinue

            if ($attempt -eq 5) {
                Write-Warning "Copy failed: $SourceFile : $($_.Exception.Message)"
                return $null
            }

            Start-Sleep -Seconds 2
        }
    }

    return $null
}

function Sync-AIPData {
    $shift = Get-CurrentShift

    foreach ($aip in $AipSources.Keys) {
        $sourceRoot = $AipSources[$aip]

        # ข้าม AIP ที่ยังไม่ได้กำหนด IP
        if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
            continue
        }

        # สร้างโฟลเดอร์ AIP และ Shift
        $destination = Join-Path $TargetRoot "$aip\$shift"

        if (!(Test-Path $destination)) {
            New-Item -ItemType Directory `
                -Path $destination -Force | Out-Null
        }

        foreach ($fileName in $FileNames) {
            $sourceFile = Join-Path $sourceRoot $fileName
            $targetFile = Join-Path $destination $fileName

            try {
                if (!(Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                    continue
                }

                $sourceInfo = Get-Item -LiteralPath $sourceFile `
                    -ErrorAction Stop

                $signature = "$($sourceInfo.Length)|$($sourceInfo.LastWriteTimeUtc.Ticks)"
                $stateKey = "$aip|$shift|$fileName"

                # คัดลอกเมื่อข้อมูลเปลี่ยน หรือปลายทางยังไม่มีไฟล์
                if ($script:LastState[$stateKey] -ne $signature -or
                    !(Test-Path -LiteralPath $targetFile)) {

                    $result = Copy-SourceFile `
                        -SourceFile $sourceFile `
                        -TargetFile $targetFile

                    if ($null -ne $result -and $result.Success) {
                        $script:LastState[$stateKey] =
                            "$($result.Length)|$($result.LastWriteTicks)"

                        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] OK: $aip\$shift\$fileName"
                    }
                }
            }
            catch {
                Write-Warning "$aip / $fileName : $($_.Exception.Message)"
            }
        }
    }
}

# สร้างโฟลเดอร์หลัก
New-Item -ItemType Directory -Path $TargetRoot -Force |
    Out-Null

Write-Host "Data_All_AIP watcher started"
Write-Host "Destination: $TargetRoot"
Write-Host "Polling interval: $PollSeconds seconds"

while ($true) {
    try {
        Sync-AIPData
    }
    catch {
        Write-Warning $_.Exception.Message
    }

    Start-Sleep -Seconds $PollSeconds
}