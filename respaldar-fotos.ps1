# =====================================================================
#  respaldar-fotos.ps1
#  Copia fotos y videos desde OneDrive (carga de cámara del teléfono)
#  al disco externo, ordenados en carpetas Año\Mes.
#  Cada copia se verifica (huella SHA-256). Al iniciar, el script pregunta
#  si además quieres borrar de OneDrive lo que quedó respaldado.
# =====================================================================

# ========================= CONFIGURACIÓN =============================
$CarpetaEnDisco = "Fotos"   # Nombre de la carpeta que se crea en el disco elegido
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

    # ---- 2. Disco de destino (se elige de una lista) ----
    $sistema = $env:SystemDrive.TrimEnd(':')

    # Qué letras corresponden a discos conectados por USB
    $letrasUsb = @{}
    try {
        Get-Partition -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object {
            $disco = $_ | Get-Disk -ErrorAction Stop
            if ($disco.BusType -eq 'USB') { $letrasUsb[[string]$_.DriveLetter] = $true }
        }
    } catch { }

    # Todas las unidades con letra, excepto la del sistema (C:)
    $unidades = @(Get-Volume | Where-Object {
                    $_.DriveLetter -and ([string]$_.DriveLetter -ne $sistema) -and
                    ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') -and $_.Size -gt 0
                  } |
                  Sort-Object @{ Expression = { -not $letrasUsb.ContainsKey([string]$_.DriveLetter) } }, DriveLetter)

    if ($unidades.Count -eq 0) {
        throw "No encontré ningún disco externo conectado. Conecta el disco y vuelve a ejecutar."
    }

    Write-Host ""
    Write-Host "Discos disponibles:"
    for ($k = 0; $k -lt $unidades.Count; $k++) {
        $v = $unidades[$k]
        $letra    = [string]$v.DriveLetter
        $nombre   = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { "(sin nombre)" }
        $tipo     = if ($letrasUsb.ContainsKey($letra)) { "USB" } elseif ($v.DriveType -eq 'Removable') { "extraíble" } else { "interno" }
        $tieneRespaldo = if (Test-Path -LiteralPath "${letra}:\$CarpetaEnDisco") { "  <- ya tiene la carpeta $CarpetaEnDisco" } else { "" }
        Write-Host ("  [{0}] {1}:  {2}  ({3})  {4:N0} GB, {5:N0} GB libres{6}" -f
                    ($k + 1), $letra, $nombre, $tipo, ($v.Size / 1GB), ($v.SizeRemaining / 1GB), $tieneRespaldo)
    }

    $eleccion = Read-Host "`nElige el número del disco (Enter = 1)"
    if ([string]::IsNullOrWhiteSpace($eleccion)) { $eleccion = "1" }
    $num = 0
    if (-not [int]::TryParse($eleccion, [ref]$num) -or $num -lt 1 -or $num -gt $unidades.Count) {
        throw "Opción no válida: $eleccion"
    }
    $unidad  = "$([string]$unidades[$num - 1].DriveLetter):"
    $Destino = Join-Path "$unidad\" $CarpetaEnDisco
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
    if ($bytes -gt $libre) {
        throw ("No hay espacio suficiente en el disco: se necesitan $gb GB y hay {0:N2} GB libres." -f ($libre / 1GB))
    }

    $resp = Read-Host "`n¿Continuar con el respaldo? (S/N)"
    if ($resp -notmatch '^[sS]') { Write-Host "Cancelado."; return }

    Write-Host ""
    Write-Host "¿Quieres BORRAR de OneDrive los archivos que queden respaldados y verificados?"
    Write-Host "Solo se borran los de este respaldo; lo demás no se toca. Quedan 30 días en la papelera de OneDrive."
    $resp = Read-Host "Borrar de OneDrive (S/N, por defecto N)"
    $BorrarOrigen = $resp -match '^[sS]'
    $BorrarExistentes = $false
    if ($BorrarOrigen) {
        Write-Host ""
        Write-Host "Algunos archivos de OneDrive pueden estar YA en el disco (idénticos, de un respaldo anterior)."
        $resp = Read-Host "¿Borrar de OneDrive también esos? (S/N, por defecto N)"
        $BorrarExistentes = $resp -match '^[sS]'
        if ($BorrarExistentes) {
            Write-Host "OK: se borrará de OneDrive lo recién copiado y lo que ya estaba en el disco." -ForegroundColor Yellow
        } else {
            Write-Host "OK: se borrará de OneDrive solo lo recién copiado; lo que ya estaba en el disco se queda en OneDrive." -ForegroundColor Yellow
        }
    } else {
        Write-Host "OK: solo se copiará; OneDrive queda intacto." -ForegroundColor Green
    }

    # ---- 4. Copiar, verificar y (opcionalmente) borrar ----
    $inicio = Get-Date
    $listaErrores     = New-Object System.Collections.Generic.List[string]
    $listaExistentes  = New-Object System.Collections.Generic.List[string]
    $copiados = 0; $yaExistian = 0; $borrados = 0; $errores = 0; $i = 0

    foreach ($f in $archivos) {
        $i++
        Write-Progress -Activity "Respaldando fotos y videos" `
                       -Status "$i de $total : $($f.Name)" `
                       -PercentComplete (100 * $i / $total)
        try {
            $fecha   = Get-FechaArchivo $f
            $carpeta = Join-Path $Destino ("{0:yyyy}\{0:MM}" -f $fecha)
            New-Item -ItemType Directory -Force -Path $carpeta | Out-Null

            # ¿El archivo estaba "solo en la nube"? (OneDrive lo descargará al leerlo)
            $eraSoloNube = (([int64]$f.Attributes -band 0x400000) -ne 0) -or
                           (($f.Attributes -band [IO.FileAttributes]::Offline) -ne 0)

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
                $listaExistentes.Add("  - $($f.Name) -> $dest")
            } else {
                Copy-Item -LiteralPath $f.FullName -Destination $dest
                if ((Get-Huella $dest) -ne $huellaOrigen) {
                    Remove-Item -LiteralPath $dest -Force
                    throw "la copia no coincide con el original"
                }
                $copiados++
            }

            # Solo se borra si la copia en el disco está verificada
            $borrar = $BorrarOrigen -and ((-not $yaEstaba) -or $BorrarExistentes)
            if ($borrar) {
                Remove-Item -LiteralPath $f.FullName -Force
                $borrados++
            } elseif ($eraSoloNube) {
                # Se queda en OneDrive: lo vuelve a dejar "solo en la nube" para no ocupar espacio en el PC
                try { & attrib.exe +U -P "$($f.FullName)" | Out-Null } catch { }
            }
        }
        catch {
            $errores++
            $listaErrores.Add("  - $($f.Name): $($_.Exception.Message)")
            Write-Host "Error con $($f.Name): $($_.Exception.Message) (se deja en OneDrive)" -ForegroundColor Red
        }
    }
    Write-Progress -Activity "Respaldando fotos y videos" -Completed

    # ---- 5. Registro: un solo archivo, el respaldo más reciente queda arriba ----
    $log = Join-Path $Destino "registro.txt"
    $bloque = New-Object System.Collections.Generic.List[string]
    $bloque.Add("==================================================")
    $bloque.Add("Respaldo del $($inicio.ToString('dd-MM-yyyy HH:mm'))")
    $bloque.Add("==================================================")
    $bloque.Add("Origen                 : $Origen")
    $bloque.Add("Borrar de OneDrive     : $(if (-not $BorrarOrigen) {'No'} elseif ($BorrarExistentes) {'Sí, incluidos los que ya estaban en el disco'} else {'Sí, solo los recién copiados'})")
    $bloque.Add("Archivos revisados     : $total")
    $bloque.Add("Copiados y verificados : $copiados")
    $bloque.Add("Ya estaban en el disco : $yaExistian")
    if ($BorrarOrigen) { $bloque.Add("Borrados de OneDrive   : $borrados") }
    $bloque.Add("Errores                : $errores")
    if ($yaExistian -gt 0) {
        $bloque.Add("Archivos que ya estaban en el disco:")
        $bloque.AddRange($listaExistentes)
    }
    if ($errores -gt 0) {
        $bloque.Add("Archivos con error (siguen en OneDrive):")
        $bloque.AddRange($listaErrores)
    }
    $bloque.Add("")
    $anterior = @()
    if (Test-Path -LiteralPath $log) { $anterior = @(Get-Content -LiteralPath $log -Encoding UTF8) }
    Set-Content -LiteralPath $log -Value (@($bloque) + $anterior) -Encoding UTF8

    Write-Host ""
    Write-Host "=== Listo ===" -ForegroundColor Green
    Write-Host "Copiados y verificados : $copiados"
    Write-Host "Ya estaban en el disco : $yaExistian"
    if ($BorrarOrigen) { Write-Host "Borrados de OneDrive   : $borrados" }
    if ($errores -gt 0) {
        Write-Host "Con errores (siguen en OneDrive): $errores" -ForegroundColor Red
    } else {
        Write-Host "Errores                : 0"
    }
    Write-Host "Registro actualizado en: $log"
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host ""
    Read-Host "Presiona Enter para cerrar" | Out-Null
}
