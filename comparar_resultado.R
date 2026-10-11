# Compara el archivo generado con el archivo exacto entregado.
# Uso:   Rscript comparar_resultado.R [archivo_generado]
# Por defecto compara salida/entrega/ensamble/E01_prof2000_ens50m_k10000.csv con resultado_esperado/E01_prof2000_ens50m_k10000.csv
args <- commandArgs(trailingOnly= TRUE)
generado <- if (length(args) >= 1) args[1] else file.path("salida", "entrega", "ensamble", "E01_prof2000_ens50m_k10000.csv")
esperado <- file.path("resultado_esperado", "E01_prof2000_ens50m_k10000.csv")
a <- readLines(generado); b <- readLines(esperado)
cat("filas generado:", length(a), "| filas esperado:", length(b), "\n")
cat("MD5 generado:", unname(tools::md5sum(generado)), "\nMD5 esperado:", unname(tools::md5sum(esperado)), "\n")
cat("ids en comun:", length(intersect(a, b)), "de", length(b), "\n")
cat("mismo orden y contenido (identico):", identical(a, b), "\n")
if (!identical(a, b)) cat("posiciones con distinto id:", sum(a[seq_len(min(length(a), length(b)))] != b[seq_len(min(length(a), length(b)))]), "\n")
