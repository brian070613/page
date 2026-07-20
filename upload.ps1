# ════════════════════════════════════
#  📸 照片上传脚本
#  用法：把新照片拖到这个窗口，或填路径
# ════════════════════════════════════

param(
  [string]$SourceDir = ""
)

$ErrorActionPreference = "Continue"
$REPO_DIR = Split-Path $Script:MyInvocation.MyCommand.Path -Parent
$PHOTOS_DIR = Join-Path $REPO_DIR "photos"
$DIST_DIR = Join-Path $REPO_DIR "dist"
$ORIGINALS_DIR = Join-Path $DIST_DIR "photos"
$HTML_FILE = Join-Path $DIST_DIR "index.html"

# === If no source provided, ask ===
if (-not $SourceDir -or -not (Test-Path $SourceDir)) {
  Write-Host "`n📸 照片上传助手" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════" -ForegroundColor Cyan
  Write-Host "请选择照片所在文件夹或输入路径："
  Write-Host "  (直接回车则打开文件选择对话框)`n" -ForegroundColor Gray
  
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "选择包含新照片的文件夹"
    $fbd.ShowNewFolderButton = $false
    if ($fbd.ShowDialog() -eq "OK") {
      $SourceDir = $fbd.SelectedPath
    } else {
      Write-Host "❌ 已取消" -ForegroundColor Red
      exit 1
    }
  } catch {
    $SourceDir = Read-Host "请输入照片文件夹路径"
    if (-not $SourceDir) { Write-Host "❌ 已取消"; exit 1 }
  }
}

if (-not (Test-Path $SourceDir)) {
  Write-Host "❌ 路径不存在: $SourceDir" -ForegroundColor Red
  exit 1
}

Write-Host "`n📂 源文件夹: $SourceDir" -ForegroundColor Yellow

# === Gather new photos ===
$imageExts = @('.jpg','.jpeg','.png','.webp','.bmp','.heic','.avif')
$newFiles = Get-ChildItem $SourceDir -File | Where-Object { $_.Extension.ToLower() -in $imageExts }
$newFiles = $newFiles | Sort-Object Name

if ($newFiles.Count -eq 0) {
  Write-Host "❌ 该文件夹没有找到图片文件" -ForegroundColor Red
  exit 1
}

Write-Host "📸 找到 $($newFiles.Count) 张新照片："
$newFiles | ForEach-Object { Write-Host "   - $($_.Name) ($([math]::Round($_.Length/1MB,1))MB)" }

# === Confirm ===
$confirm = Read-Host "`n是否继续上传？(Y/n)"
if ($confirm -eq '' -or $confirm -eq 'y' -or $confirm -eq 'Y') {
  # proceed
} else {
  Write-Host "❌ 已取消" -ForegroundColor Red
  exit 0
}

# === Step 1: Copy originals to repo ===
Write-Host "`n[1/4] 复制原始照片到仓库..." -ForegroundColor Green
New-Item -ItemType Directory -Path $PHOTOS_DIR -Force | Out-Null
$copiedOriginals = @()
foreach ($f in $newFiles) {
  $dest = Join-Path $PHOTOS_DIR $f.Name
  Copy-Item $f.FullName $dest -Force
  Write-Host "   ✓ $($f.Name)"
  $copiedOriginals += $f.Name
}

# === Step 2: Compress for web (dist/photos) ===
Write-Host "`n[2/4] 压缩照片用于网页..." -ForegroundColor Green
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Path $ORIGINALS_DIR -Force | Out-Null

$maxWidth = 1920
$maxHeight = 1920
$quality = 80L

foreach ($f in $newFiles) {
  $outputPath = Join-Path $ORIGINALS_DIR $f.Name
  try {
    $img = [System.Drawing.Image]::FromFile($f.FullName)
    $ratio = [Math]::Min($maxWidth / $img.Width, $maxHeight / $img.Height)
    if ($ratio -gt 1) { $ratio = 1 }
    $newW = [int][Math]::Round($img.Width * $ratio)
    $newH = [int][Math]::Round($img.Height * $ratio)
    
    $bmp = New-Object System.Drawing.Bitmap($newW, $newH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($img, 0, 0, $newW, $newH)
    $g.Dispose()
    
    if ($f.Extension.ToLower() -eq ".png") {
      $bmp.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } else {
      $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
      $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, $quality)
      $jpgCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.FormatDescription -eq "JPEG" }
      $bmp.Save($outputPath, $jpgCodec, $encoderParams)
    }
    $bmp.Dispose()
    $img.Dispose()
    $origMB = [math]::Round($f.Length / 1MB, 1)
    $newMB = [math]::Round((Get-Item $outputPath).Length / 1MB, 1)
    Write-Host "   ✓ $($f.Name)  ${origMB}MB → ${newMB}MB"
  } catch {
    Write-Host "   ✗ $($f.Name) 压缩失败: $_" -ForegroundColor Red
    Copy-Item $f.FullName $outputPath
  }
}

# === Step 3: Update HTML photo list ===
Write-Host "`n[3/4] 更新网页照片列表..." -ForegroundColor Green

# Get all photos sorted
$allPhotos = Get-ChildItem $ORIGINALS_DIR -File | Where-Object { $_.Extension.ToLower() -in $imageExts } | Sort-Object Name
$photoNames = $allPhotos.Name | ForEach-Object { "`"$_`"" }
$photoArray = $photoNames -join ",`n    "

# Read current HTML and update the photos array
$html = Get-Content $HTML_FILE -Raw -Encoding UTF8
$pattern = '(?<=let photos = \[)(.|\n)*?(?=\];)'
$replacement = "`n    $photoArray`n  "
$html = [regex]::Replace($html, $pattern, $replacement)
Set-Content $HTML_FILE $html -Encoding UTF8 -NoNewline
Write-Host "   ✓ 共 $($allPhotos.Count) 张照片已更新"

# === Step 4: Commit and push ===
Write-Host "`n[4/4] 推送到 GitHub..." -ForegroundColor Green
Set-Location $REPO_DIR

# Copy updated HTML to repo root too
Copy-Item $HTML_FILE (Join-Path $REPO_DIR "index.html") -Force

# Add originals
git add photos/ index.html 2>&1 | Out-Null
# Add compressed
git add dist/photos/ dist/index.html 2>&1 | Out-Null

$hasChanges = git status --porcelain
if ($hasChanges) {
  $dateStr = Get-Date -Format "yyyy-MM-dd HH:mm"
  git commit -m "📸 更新照片 ($dateStr)" 2>&1 | Out-Null
  Write-Host "   📤 正在推送..." -ForegroundColor Yellow
  git push origin main 2>&1 | ForEach-Object { Write-Host "      $_" }
  Write-Host "   ✅ 已成功推送！" -ForegroundColor Green
} else {
  Write-Host "   ℹ️ 没有新变更" -ForegroundColor Yellow
}

Set-Location $REPO_DIR

Write-Host "`n" -NoNewline
Write-Host "🎉 全部完成！" -ForegroundColor Cyan
Write-Host "═══════════════════════════════" -ForegroundColor Cyan
Write-Host "网站地址: https://brian070613.github.io/page/" -ForegroundColor White
Write-Host "CDN加速地址: https://cdn.jsdelivr.net/gh/brian070613/page@main/photos/" -ForegroundColor Gray
Write-Host "`n⏎ 按回车键退出..."
Read-Host
