# =====================================================================
#  respaldar-fotos.ps1
#  Mueve fotos y videos desde OneDrive (carga de cámara del teléfono)
#  al disco externo, ordenados en carpetas Año\Mes.
#  Cada archivo se verifica (huella SHA-256) antes de borrarlo del origen.
# =====================================================================

# ========================= CONFIGURACIÓN =============================
$Destino      = "E:\Fotos"   # Carpeta raíz en el disco externo (cambia la letra si corresponde)
$BorrarOrigen = $true        # $false = solo copia, no borra nada de OneDrive
# =====================================================================

$ErrorActionPreference = "Stop"
$Extensiones = @(".jpg",".jpeg",".png",".heic",".heif",".webp",".gif",".dng",
                 ".mp4",".mov",".3gp",".mkv",".webm")

function Get-FechaArchivo($f) {
    # Los nombres de Android suelen traer la fecha: IMG_20261005_..., PXL_2026..., VID_..., Screenshot_...
    if ($f.Name -match '(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])') {
        $anio = [int]$matches[1]
        if ($anio -le (Get-Date).Year) {
            return [datetime]::new($anio, [int]$matches[2], [int]$matches[3])
        }
    }
    return $f.LastWriteTime   # Si el nombre no trae fecha, usa la fecha del archivo
}

function Get-Huella($ruta) {
    return (Get-FileHash -LiteralPath $ruta -Algorithm SHA256).Hash
}

try {
    Write-Host "=== Respaldo de fotos: OneDrive -> disco externo ===" -ForegroundColor Cyan

    # ---- 1. Carpeta de origen (OneDrive) ----
    $od = $env:OneDrive
    if (-not $od) { $od = $env:OneDriveConsumer }
    $candidatos = @(
        "$od\Pictures\Camera Roll",
        "$od\Imágenes\Álbum de cámara",
        "$od\Imágenes\Camera Roll",
        "$od\Pictures\Álbum de cámara"
    )
    $Origen = $candidatos | Where-Object { $od -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $Origen) {
        throw "No encontré la carpeta de carga de cámara de OneDrive. Revisa que OneDrive esté instalado y sincronizando."
    }

    # ---- 2. Disco de destino ----
    $unidad = Split-Path -Qualifier $Destino
    if (-not (Test-Path -LiteralPath "$unidad\")) {
        throw "El disco $unidad no está conectado. Conéctalo (o cambia la letra en la configuración del script)."
    }
    New-Item -ItemType Directory -Force -Path $Destino | Out-Null

    # ---- 3. Archivos a respaldar ----
    $archivos = @(Get-ChildItem -LiteralPath $Origen -File -Recurse |
                  Where-Object { $Extensiones -contains $_.Extension.ToLower() })
    $total = $archivos.Count
    if ($total -eq 0) {
        Write-Host "No hay fotos ni videos nuevos en OneDrive. Nada que hacer." -ForegroundColor Green
        return
    }

    $bytes = ($archivos | Measure-Object Length -Sum).Sum
    $libre = (Get-PSDrive -Name $unidad.TrimEnd(':')).Free
    $gb = "{0:N2}" -f ($bytes / 1GB)

    Write-Host ""
    Write-Host "Origen : $Origen"
    Write-Host "Destino: $Destino"
    Write-Host "Archivos encontrados: $total ($gb GB)"
    if ($BorrarOrigen) {
        Write-Host "Al terminar, los archivos verificados se BORRARÁN de OneDrive" -ForegroundColor Yellow
        Write-Host "(quedan 30 días en la papelera de OneDrive por si acaso)." -ForegroundColor Yellow
    } else {
        Write-Host "Modo solo copia: no se borrará nada de OneDrive."
    }
    if ($bytes -gt $libre) {
        throw ("No hay espacio suficiente en el disco: se necesitan $gb GB y hay {0:N2} GB libres." -f ($libre / 1GB))
    }

    $resp = Read-Host "`n¿Continuar? (S/N)"
    if ($resp -notmatch '^[sS]') { Write-Host "Cancelado."; return }

    # ---- 4. Copiar, verificar y (opcionalmente) borrar ----
    $log = Join-Path $Destino ("registro_" + (Get-Date -Format "yyyy-MM-dd_HHmmss") + ".txt")
    function Registrar($texto) { Add-Content -LiteralPath $log -Value $texto -Encoding UTF8 }
    Registrar "Respaldo iniciado $(Get-Date) | Origen: $Origen"

    $copiados = 0; $yaExistian = 0; $errores = 0; $i = 0

    foreach ($f in $archivos) {
        $i++
        Write-Progress -Activity "Respaldando fotos y videos" `
                       -Status "$i de $total : $($f.Name)" `
                       -PercentComplete (100 * $i / $total)
        try {
            $fecha   = Get-FechaArchivo $f
            $carpeta = Join-Path $Destino ("{0:yyyy}\{0:MM}" -f $fecha)
            New-Item -ItemType Directory -Force -Path $carpeta | Out-Null

            $huellaOrigen = Get-Huella $f.FullName   # (descarga el archivo si OneDrive lo tenía solo en la nube)

            # Si ya existe un archivo con el mismo nombre: si es idéntico se omite,
            # si es distinto se guarda con sufijo _1, _2, ...
            $dest = Join-Path $carpeta $f.Name
            $n = 1; $yaEstaba = $false
            while (Test-Path -LiteralPath $dest) {
                if ((Get-Huella $dest) -eq $huellaOrigen) { $yaEstaba = $true; break }
                $dest = Join-Path $carpeta ("{0}_{1}{2}" -f $f.BaseName, $n, $f.Extension)
                $n++
            }

            if ($yaEstaba) {
                $yaExistian++
                Registrar "YA EXISTÍA  $($f.Name) -> $dest"
            } else {
                Copy-Item -LiteralPath $f.FullName -Destination $dest
                if ((Get-Huella $dest) -ne $huellaOrigen) {
                    Remove-Item -LiteralPath $dest -Force
                    throw "la copia no coincide con el original"
                }
                $copiados++
                Registrar "COPIADO     $($f.Name) -> $dest"
            }

            # Solo se borra si la copia en el disco está verificada
            if ($BorrarOrigen) { Remove-Item -LiteralPath $f.FullName -Force }
        }
        catch {
            $errores++
            Registrar "ERROR       $($f.Name): $($_.Exception.Message)"
            Write-Host "Error con $($f.Name): $($_.Exception.Message) (se deja en OneDrive)" -ForegroundColor Red
        }
    }
    Write-Progress -Activity "Respaldando fotos y videos" -Completed

    # ---- 5. Resumen ----
    Registrar "Fin $(Get-Date) | Copiados: $copiados | Ya existían: $yaExistian | Errores: $errores"
    Write-Host ""
    Write-Host "=== Listo ===" -ForegroundColor Green
    Write-Host "Copiados y verificados : $copiados"
    Write-Host "Ya estaban en el disco : $yaExistian"
    if ($errores -gt 0) {
        Write-Host "Con errores (siguen en OneDrive): $errores" -ForegroundColor Red
    } else {
        Write-Host "Errores                : 0"
    }
    Write-Host "Registro guardado en: $log"
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host ""
    Read-Host "Presiona Enter para cerrar" | Out-Null
}
