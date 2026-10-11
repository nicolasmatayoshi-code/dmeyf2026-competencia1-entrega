# ======================================================================
# MODELO FINAL (entrega E01prof_ens50): 50 modelos LightGBM, ensamble, 10.000 envios
# ======================================================================
# Primera Competencia DMEyF 2026: prediccion de BAJA+2 en 202108.
# Parte del dataset crudo y llega al archivo final de la entrega.
# Pipeline: crudo -> clase_ternaria -> data quality (ccajas_depositos = NA en 202105) -> lags y delta lags 1 y 2
# (760 columnas, valores originales, sin undersampling) -> 50 modelos con identicos hiperparametros y semillas distintas,
# entrenados en 202103-202106 -> prediccion de 202108 -> promedio simple de probabilidades -> 10.000 mejores clientes.
# Uso:   Rscript modelo_final.R > modelo_final.log 2>&1
# Rutas (variables de entorno, opcionales):
#   DMEYF_CRUDO = ruta de competencia_01_crudo.csv   (por defecto ./competencia_01_crudo.csv)
#   DMEYF_EXP   = carpeta de salida                  (por defecto ./salida)
# Reanudable: lo que ya esta guardado en la carpeta de salida no se recalcula. No envia nada a ningun sitio.

suppressMessages(library(data.table))
paquete_lgb <- if (requireNamespace("zlightgbm", quietly= TRUE)) "zlightgbm" else "lightgbm"   # se uso zlightgbm 4.6.0.99
suppressMessages(library(paquete_lgb, character.only= TRUE))
cat("R:", R.version.string, "| LightGBM:", paquete_lgb, as.character(packageVersion(paquete_lgb)),
    "| data.table:", as.character(packageVersion("data.table")), "\n")

RUTA_CRUDO  <- normalizePath(Sys.getenv("DMEYF_CRUDO", unset= "competencia_01_crudo.csv"), mustWork= FALSE)
RUTA_SALIDA <- normalizePath(Sys.getenv("DMEYF_EXP",   unset= "salida"), mustWork= FALSE)
dir.create(RUTA_SALIDA, showWarnings= FALSE, recursive= TRUE)

# ======================================================================
# PARAMETROS
# ======================================================================
PARAM <- list()
PARAM$experimento <- "E01_prof2000"
PARAM$semilla_primigenia <- 765461L                 # de ella salen todas las semillas de los modelos

PARAM$meses_final  <- c(202103, 202104, 202105, 202106)   # meses de entrenamiento del modelo final
PARAM$mes_futuro   <- 202108                              # mes a predecir
PARAM$meses_pseudo <- c(202103, 202104)                   # solo para la verificacion del positivo-ancla
PARAM$clase_positiva <- c("BAJA+1", "BAJA+2")             # clase01 = 1; CONTINUA = 0
PARAM$dq_campo    <- "ccajas_depositos"                   # variable rota en 202105 (todos ceros): se pone NA
PARAM$dq_mes_roto <- 202105
PARAM$ordenes_lag <- 1:2                                  # lag y delta lag de orden 1 y 2

# LightGBM: parametros fijos (iguales en todos los modelos). num_threads fijo y explicito: 14 (corrida original).
PARAM$lgb <- list(
  boosting= "gbdt", objective= "binary", metric= "auc", first_metric_only= FALSE,
  boost_from_average= TRUE, feature_pre_filter= FALSE, force_row_wise= TRUE, verbosity= -1,
  max_depth= -1L, min_gain_to_split= 0, lambda_l1= 0, lambda_l2= 0,
  max_bin= 31L, min_data_in_leaf= 0L,
  bagging_fraction= 1, pos_bagging_fraction= 1, neg_bagging_fraction= 1,
  is_unbalance= FALSE, scale_pos_weight= 1, extra_trees= FALSE,
  learning_rate= 0.005, feature_fraction= 0.5, feature_fraction_bynode= 0.2,
  num_threads= 14L
)
# Hiperparametros del modelo. Fijados a mano; NO provienen de una optimizacion bayesiana (no hay ninguna en esta cadena).
PARAM$hojas    <- 254L          # num_leaves
PARAM$hessiano <- 4.84e-4       # min_sum_hessian_in_leaf
PARAM$arboles  <- 2000L         # num_iterations: elegido con 01_eleccion_cantidad_de_arboles (centro de la meseta 1500-2500)
PARAM$n_modelos <- as.integer(Sys.getenv("DMEYF_NMODELOS", unset= "50"))   # entrega final: 50 (un valor menor solo sirve para pruebas)
PARAM$corte_final <- 10000L     # clientes enviados (el bot acepta 8000 a 15000)

# Anclas: si no coinciden, el dato cambio y el script se detiene.
PARAM$ancla_npos_pseudo <- 4082L     # positivos BAJA+1/BAJA+2 de 202103-04
PARAM$ancla_vars_base   <- 152L      # variables del crudo sin numero_de_cliente, foto_mes ni clase
PARAM$ancla_ncols       <- 760L      # 152 variables x (original + lag1 + delta1 + lag2 + delta2)

# Semillas (metodo de la catedra): primos entre 100000 y 1000000, set.seed(primigenia), sample(primos, n).
primos_entre <- function(a, b) {
  x <- rep(TRUE, b); x[1] <- FALSE
  for (i in 2:floor(sqrt(b))) if (x[i]) x[seq(i * i, b, by= i)] <- FALSE
  p <- which(x)
  p[p >= a]
}
set.seed(PARAM$semilla_primigenia)
PARAM$semillas <- sample(primos_entre(100000L, 1000000L), PARAM$n_modelos)
if (anyDuplicated(PARAM$semillas) > 0) stop("hay semillas repetidas")
if (!all(PARAM$semillas[1:min(5, PARAM$n_modelos)] == c(125269L, 175853L, 691651L, 593507L, 593083L)[1:min(5, PARAM$n_modelos)])) stop("las semillas no coinciden con las esperadas")
cat("semillas:", PARAM$semillas, "\n")

writeLines(capture.output(dput(PARAM)), file.path(RUTA_SALIDA, "PARAM.txt"))
writeLines(capture.output(sessionInfo()), file.path(RUTA_SALIDA, "sessionInfo.txt"))
t_inicio <- Sys.time()
minutos <- function(desde) round(as.numeric(difftime(Sys.time(), desde, units= "mins")), 1)

# ======================================================================
# PASO 1 - LECTURA DEL DATASET CRUDO
# ======================================================================
if (!file.exists(RUTA_CRUDO)) stop("No encuentro el dataset en: ", RUTA_CRUDO)
dataset <- fread(RUTA_CRUDO)
cat("filas:", nrow(dataset), " columnas:", ncol(dataset), "\n")
faltan <- setdiff(c(PARAM$meses_final, PARAM$mes_futuro), unique(dataset$foto_mes))
if (length(faltan) > 0) stop("faltan meses en el crudo: ", paste(faltan, collapse= ", "))

# ======================================================================
# PASO 2 - CLASE_TERNARIA (codigo de la catedra)
# ======================================================================
# BAJA+1: no esta el mes siguiente. BAJA+2: esta el mes siguiente pero no a los dos meses. CONTINUA: el resto.
# Los ultimos dos meses del crudo quedan con clase NA (falta futuro para saberla).
tabla_periodos <- dataset[, list(pos= .I, numero_de_cliente,
                                 periodo0= as.integer(foto_mes / 100) * 12 + foto_mes %% 100)]
setorder(tabla_periodos, numero_de_cliente, periodo0)
periodo_ultimo     <- tabla_periodos[, max(periodo0)]
periodo_anteultimo <- periodo_ultimo - 1
tabla_periodos[, c("periodo1", "periodo2") := shift(periodo0, n= 1:2, fill= NA, type= "lead"), numero_de_cliente]
tabla_periodos[periodo0 < periodo_anteultimo, clase_ternaria := "CONTINUA"]
tabla_periodos[periodo0 < periodo_ultimo & (is.na(periodo1) | periodo0 + 1 < periodo1), clase_ternaria := "BAJA+1"]
tabla_periodos[periodo0 < periodo_anteultimo & (periodo0 + 1 == periodo1) & (is.na(periodo2) | periodo0 + 2 < periodo2),
               clase_ternaria := "BAJA+2"]
setorder(tabla_periodos, pos)
dataset[, clase_ternaria := tabla_periodos$clase_ternaria]
rm(tabla_periodos)
if (dataset[foto_mes %in% PARAM$meses_final & is.na(clase_ternaria), .N] > 0) stop("hay filas de entrenamiento sin clase_ternaria")

# ======================================================================
# PASO 3 - DATA QUALITY Y CLASE BINARIA
# ======================================================================
# ccajas_depositos esta rota en 202105 (todos ceros): NA solo en ese mes.
if (!(PARAM$dq_campo %in% names(dataset))) stop("no existe la columna ", PARAM$dq_campo)
dataset[foto_mes == PARAM$dq_mes_roto, (PARAM$dq_campo) := NA_real_]

dataset[, clase01 := ifelse(clase_ternaria %in% PARAM$clase_positiva, 1L, 0L)]
npos_pseudo <- dataset[foto_mes %in% PARAM$meses_pseudo & clase01 == 1L, .N]
cat("positivos 202103-04:", npos_pseudo, "| ancla:", PARAM$ancla_npos_pseudo, "\n")
if (npos_pseudo != PARAM$ancla_npos_pseudo) stop("la clase no coincide con el ancla: no sigo")

# orden fijo (cliente, mes): hace reproducible el orden de las filas
setorder(dataset, numero_de_cliente, foto_mes)
vars_base <- setdiff(names(dataset), c("numero_de_cliente", "foto_mes", "clase_ternaria", "clase01"))
for (v in vars_base) if (!is.numeric(dataset[[v]])) set(dataset, j= v, value= as.numeric(dataset[[v]]))
cat("variables base:", length(vars_base), "| ancla:", PARAM$ancla_vars_base, "\n")
if (length(vars_base) != PARAM$ancla_vars_base) stop("la cantidad de variables base no coincide con el ancla")

# ======================================================================
# PASO 4 - LAGS Y DELTA LAGS DE ORDEN 1 Y 2
# ======================================================================
# Se usan los valores originales (sin ranking ni transformacion). Los NA se dejan como NA.
# lag de orden k = valor del MISMO cliente exactamente k meses calendario antes (NA si ese mes no existe).
# delta = valor actual - lag. Cada variable queda con 5 columnas: original, lag1, delta1, lag2, delta2.
id_cliente <- dataset$numero_de_cliente
mes_entero <- as.integer(dataset$foto_mes / 100) * 12L + dataset$foto_mes %% 100L
clave      <- as.numeric(id_cliente) * 1e5 + mes_entero        # clave unica cliente x mes (< 2^53)
if (anyDuplicated(clave) > 0) stop("hay mas de una fila por cliente y mes")
fila_lag <- lapply(PARAM$ordenes_lag, function(k) match(clave - k, clave))   # fila del mismo cliente k meses antes
names(fila_lag) <- PARAM$ordenes_lag
rm(clave, mes_entero)

nombres_columnas <- c(vars_base, unlist(lapply(PARAM$ordenes_lag, function(k) c(paste0(vars_base, "_lag", k), paste0(vars_base, "_delta", k)))))
if (length(nombres_columnas) != PARAM$ancla_ncols) stop("la cantidad de columnas no coincide con el ancla")

# ======================================================================
# PASO 5 - MATRICES (se arman por columna para no duplicar memoria)
# ======================================================================
# Orden de filas: por mes y por cliente.
meses_dataset <- dataset$foto_mes
filas_ordenadas <- function(filas) filas[order(meses_dataset[filas], id_cliente[filas])]
filas_final  <- filas_ordenadas(which(meses_dataset %in% PARAM$meses_final))
filas_futuro <- filas_ordenadas(which(meses_dataset == PARAM$mes_futuro))

armar_matriz <- function(filas) {
  m <- matrix(NA_real_, nrow= length(filas), ncol= length(nombres_columnas), dimnames= list(NULL, nombres_columnas))
  for (j in seq_along(vars_base)) {
    x <- dataset[[vars_base[j]]]
    m[, vars_base[j]] <- x[filas]
    for (k in PARAM$ordenes_lag) {
      lag_k <- x[fila_lag[[as.character(k)]]]
      m[, paste0(vars_base[j], "_lag", k)]   <- lag_k[filas]
      m[, paste0(vars_base[j], "_delta", k)] <- (x - lag_k)[filas]
    }
  }
  m
}

y_final    <- dataset$clase01[filas_final]
ids_futuro <- id_cliente[filas_futuro]
if (anyDuplicated(ids_futuro) > 0) stop("hay clientes repetidos en el mes a predecir")

matriz_final  <- armar_matriz(filas_final)
matriz_futuro <- armar_matriz(filas_futuro)
rm(dataset, fila_lag, filas_final, filas_futuro, meses_dataset, id_cliente)
invisible(gc(full= TRUE, verbose= FALSE))
cat(sprintf("matriz de entrenamiento: %d x %d | futuro %d: %d clientes | positivos: %d (%.2f%%)\n",
            nrow(matriz_final), ncol(matriz_final), PARAM$mes_futuro, nrow(matriz_futuro), sum(y_final), 100 * mean(y_final)))

# entrena un modelo LightGBM con la semilla dada (lo unico que cambia entre modelos es la semilla)
entrenar_modelo <- function(matriz, y, arboles, semilla) {
  p <- modifyList(PARAM$lgb, list(num_iterations= arboles, num_leaves= PARAM$hojas,
                                  min_sum_hessian_in_leaf= PARAM$hessiano, seed= semilla))
  dtrain <- lgb.Dataset(matriz, label= y, params= list(feature_pre_filter= FALSE, max_bin= PARAM$lgb$max_bin))
  lgb.train(params= p, data= dtrain, nrounds= arboles)
}

# ======================================================================
# PASO 6 - ENTRENAMIENTO FINAL (202103-06, sin undersampling) Y PREDICCION DE 202108
# ======================================================================
# Un modelo por semilla; cada uno guarda modelos/prob_prof_s<semilla>.csv. Si el archivo existe se salta (reanudable).
dir_modelos <- file.path(RUTA_SALIDA, "modelos"); dir.create(dir_modelos, showWarnings= FALSE)
plan <- data.table(semilla= PARAM$semillas)
plan[, nombre := sprintf("prof_s%d", semilla)]
plan[, archivo := file.path(dir_modelos, paste0("prob_", nombre, ".csv"))]
t_modelos <- Sys.time()
for (i in seq_len(nrow(plan))) {
  m <- plan[i]
  if (file.exists(m$archivo)) { cat(sprintf("[%d/%d] %s ya existe\n", i, nrow(plan), m$nombre)); next }
  t0 <- Sys.time()
  prob <- predict(entrenar_modelo(matriz_final, y_final, PARAM$arboles, m$semilla), matriz_futuro)
  if (length(prob) != length(ids_futuro)) stop("la prediccion no tiene una fila por cliente")
  fwrite(data.table(numero_de_cliente= ids_futuro, prob= prob), paste0(m$archivo, ".tmp"))
  file.rename(paste0(m$archivo, ".tmp"), m$archivo)
  cat(sprintf("[%d/%d] %s listo en %.1f min | acumulado %.0f min\n", i, nrow(plan), m$nombre, minutos(t0), minutos(t_modelos)))
  invisible(gc())
}

# ======================================================================
# PASO 7 - ENSAMBLE (promedio simple de probabilidades por numero_de_cliente) Y CORTE
# ======================================================================
probs <- rbindlist(lapply(plan$archivo, function(f) {
  x <- fread(f); x[, modelo := sub("^prob_(.*)\\.csv$", "\\1", basename(f))]; x
}))
if (any(probs[, .N, modelo]$N != length(ids_futuro))) stop("algun modelo no tiene una fila por cliente de 202108")
if (anyDuplicated(probs[, .(modelo, numero_de_cliente)]) > 0) stop("hay clientes repetidos dentro de un modelo")
ensamble <- probs[, list(prob= mean(prob), n_modelos= .N), numero_de_cliente]
if (nrow(ensamble) != length(ids_futuro) || any(ensamble$n_modelos != nrow(plan))) stop("el promedio no uso todos los modelos")
fwrite(ensamble[, .(numero_de_cliente, prob)], file.path(RUTA_SALIDA, "prob_ensamble_202108.csv"))

# Envio: los PARAM$corte_final clientes con mayor probabilidad promedio. Un id por linea, entero, sin encabezado.
dir_ens <- file.path(RUTA_SALIDA, "entrega", "ensamble"); dir.create(dir_ens, recursive= TRUE, showWarnings= FALSE)
archivo_final <- file.path(dir_ens, sprintf("%s_ens%dm_k%d.csv", PARAM$experimento, nrow(plan), PARAM$corte_final))
ids_envio <- ensamble[order(-prob)][seq_len(PARAM$corte_final), as.integer(numero_de_cliente)]
fwrite(data.table(ids_envio), archivo_final, col.names= FALSE, quote= FALSE, scipen= 100, eol= "\n")

# ======================================================================
# PASO 8 - VALIDACION DE FORMATO
# ======================================================================
# Entre 8000 y 15000 filas, solo enteros sin encabezado, sin repetidos y solo clientes de 202108.
x <- readLines(archivo_final)
stopifnot(length(x) >= 8000, length(x) <= 15000, all(grepl("^[0-9]+$", x)), !anyDuplicated(x), all(as.integer(x) %in% ids_futuro))
cat("archivo final:", archivo_final, "|", length(x), "filas | formato OK\n")
cat("FIN | minutos totales:", minutos(t_inicio), "\n")
