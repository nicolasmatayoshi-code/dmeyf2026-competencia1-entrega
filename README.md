# Primera Competencia DMEyF 2026 - Entrega final

Prediccion de BAJA+2 en el mes 202108 (churn bancario). La entrega es **un solo archivo**: los **10.000** clientes con mayor
probabilidad promedio de un ensamble de **50 modelos LightGBM** que solo se diferencian en la semilla.

- Nombre del submit: `E01prof_ens50`
- Archivo entregado: `E01_prof2000_ens50m_k10000.csv` (esta en `resultado_esperado/`)
- La entrega se hizo por el bot de Zulip (`@competencia-uno`), no por Kaggle.

## Enfoque

- Variables: las 152 variables originales del dataset (valores crudos, NA sin tocar) mas **lag y delta lag de orden 1 y 2**
  de cada una (760 columnas). Sin ranking, sin undersampling, sin seleccion de variables.
- Data quality: `ccajas_depositos` se pone en `NA` solo en 202105 (mes en el que viene toda en cero).
- Clase: 1 si `clase_ternaria` es BAJA+1 o BAJA+2; 0 si es CONTINUA. `clase_ternaria` se calcula con el codigo de la catedra.
- Entrenamiento: 202103 a 202106. Prediccion: 202108.
- Modelo: LightGBM, 254 hojas, 2000 arboles, 50 semillas distintas con identicos hiperparametros. Ensamble por promedio simple de
  probabilidades por `numero_de_cliente`. Se envian los 10.000 mejores.

## Hiperparametros: de donde salen (leer con atencion)

**No hay una optimizacion bayesiana en esta cadena.** No existe un log de BO del que se tomen los hiperparametros.

| Hiperparametro | Valor | Como se fijo |
|---|---|---|
| learning_rate | 0.005 | fijo, segun los tips de la catedra |
| max_bin | 31 | fijo, segun los tips de la catedra |
| min_data_in_leaf | 0 | fijo, segun los tips de la catedra |
| feature_fraction | 0.50 | fijo, segun los tips de la catedra |
| feature_fraction_bynode | 0.20 | fijo, segun los tips de la catedra |
| metric | auc | fijo, segun los tips de la catedra |
| num_leaves | 254 | **fijado a mano** |
| min_sum_hessian_in_leaf | 4.84e-4 | **fijado a mano** |
| num_iterations | 2000 | elegido con la corrida `01_eleccion_cantidad_de_arboles` (decision manual sobre sus resultados) |

Para el numero de arboles, `01_eleccion_cantidad_de_arboles` entrena 3 modelos con 254 hojas y hessiano 4.84e-4 sobre 202103-04,
con hasta 4000 arboles, y mide la ganancia en 202106 (mes con clase conocida) con 1000 a 4000 arboles del mismo modelo. La ganancia
media entre 9000 y 14000 envios del ensamble de las 3 semillas fue (millones): 389,2 con 1000 arboles; 395,4 con 1500; 393,1 con 2000;
392,8 con 2500; 389,3 con 3000; 387,6 con 3500; 386,6 con 4000. Se tomo **2000**, el centro de la meseta de 1500 a 2500, y no el pico.
El resultado de la corrida original esta en `01_eleccion_cantidad_de_arboles/log_original/`.

El corte de **10.000** envios se fijo a mano dentro de lo que acepta el bot (8000 a 15000).

## Estructura

```
README.md
.gitignore
resultado_esperado/
    E01_prof2000_ens50m_k10000.csv           archivo exacto subido como entrega final
    MD5.txt, SHA256.txt                      huellas del archivo
01_eleccion_cantidad_de_arboles/
    eleccion_cantidad_de_arboles.R           script (opcional: solo justifica los 2000 arboles)
    log_original/                            log, PARAM y resultado de la corrida original
02_modelo_final/
    modelo_final.R                           script: del dataset crudo al archivo final
    log_original/                            logs de las 3 corridas encadenadas y PARAM original
```

## Requisitos y versiones

- R 4.3.1 (ucrt, Windows 11), `data.table` 1.14.8 y `zlightgbm` 4.6.0.99 (el paquete LightGBM de la catedra; si no esta, el script usa
  `lightgbm`, pero el resultado puede variar). Sistema: Windows 11 x64, R 4.3.1 (ucrt), `Matrix` 1.5-4.1, `jsonlite` 1.8.7.
- Instalacion de zlightgbm: `install.packages("https://storage.googleapis.com/open-courses/dmeyf2025-e4a2/zlightgbm_4.6.0.99.tar.gz", repos = NULL, type = "source")`
- RAM: la matriz de entrenamiento (654.066 filas x 760 columnas) ocupa unos 4 GB; el proceso llega a 7 GB. Recomendados 16 GB.
- Threads: `num_threads = 14` fijo en el script (la corrida original uso 14 hilos en una PC de 16 nucleos).

## Dataset

No se incluye en el repositorio. Se descarga de la catedra:

```bash
wget https://storage.googleapis.com/open-courses/dmeyf2026-9c6f/competencia_01_crudo.csv
```

MD5 del archivo usado: `b6f759764c5d04cbf068548517ae1249`.

## Como reproducir (orden de ejecucion)

Poner `competencia_01_crudo.csv` en la carpeta desde donde se ejecuta (o definir `DMEYF_CRUDO`) y, opcionalmente, `DMEYF_EXP` para la salida
(por defecto `./salida`).

| Paso | Comando | Produce | Tiempo aprox. |
|---|---|---|---|
| 1 (opcional) | `Rscript 01_eleccion_cantidad_de_arboles/eleccion_cantidad_de_arboles.R` | `salida/pseudo_profundo_por_arboles.csv` | 55 min |
| 2 | `Rscript 02_modelo_final/modelo_final.R` | 50 archivos `salida/modelos/prob_prof_s<semilla>.csv` y `salida/entrega/ensamble/E01_prof2000_ens50m_k10000.csv` | 10 a 12 h (12 a 15 min por modelo) |
| 3 | `md5sum salida/entrega/ensamble/E01_prof2000_ens50m_k10000.csv` y comparar con `resultado_esperado/MD5.txt` | MD5 del archivo generado | segundos |

El paso 1 no alimenta al paso 2: es la evidencia de la eleccion de los 2000 arboles, que en el paso 2 figura en `PARAM$arboles`.
El script del paso 2 es reanudable: si se corta, se vuelve a ejecutar y salta los modelos ya terminados.

**Aclaracion sobre la BO.** Como no hay BO, no hay un paso "(a) todo desde la BO". La unica ruta es la de arriba, que parte del dataset crudo.
La cadena original se corrio en tres tandas del mismo script (modelos 1 a 5, luego hasta 20 y luego hasta 50, reutilizando los modelos ya
terminados); los tres logs estan en `02_modelo_final/log_original/`.

## Verificacion realizada

No se repitio la corrida completa (50 modelos, unas 10 a 12 horas). Se verifico asi:

1. **Reproduccion de modelos.** Con una sesion nueva de R, desde el dataset crudo y con el script `02_modelo_final/modelo_final.R` limpio
   (con `DMEYF_NMODELOS=2`), se reentrenaron los dos primeros modelos (semillas 125269 y 175853) en la misma maquina y con 14 hilos.
   Los archivos de probabilidades resultantes tienen el **mismo MD5** que los de la corrida original:

   | Modelo | MD5 reproducido | MD5 original |
   |---|---|---|
   | `prob_prof_s125269.csv` | a047f5c7a1fc6d6f11c7fe8683028689 | a047f5c7a1fc6d6f11c7fe8683028689 |
   | `prob_prof_s175853.csv` | fa94c6f765ab90386dde4af729eb6f4f | fa94c6f765ab90386dde4af729eb6f4f |

2. **Tramo posterior a los modelos.** A partir de las 50 probabilidades guardadas de la corrida original, el promedio por cliente y los 10.000
   mejores dan exactamente los mismos ids y en el mismo orden que el archivo entregado.
3. **Lo que no se verifico.** No se reentrenaron los otros 48 modelos. El script `01_eleccion_cantidad_de_arboles/eleccion_cantidad_de_arboles.R`
   se limpio para este repositorio y solo se comprobo que su sintaxis es valida; sus resultados son los de la corrida original
   (`01_eleccion_cantidad_de_arboles/log_original/`), que se hizo con una version anterior del mismo codigo.
   El archivo entregado es la reunion de las tres tandas descritas arriba; el paso de unirlas es el de la verificacion 2.

## Sobre la reproduccion exacta

LightGBM no se corrio con `deterministic = TRUE` y entrena con varios hilos. Con otra cantidad de hilos, otra version del paquete u otro
sistema operativo es posible que las probabilidades cambien en los ultimos decimales y que algunos clientes del borde del corte de 10.000
cambien. El archivo generado debe tener el MD5 de `resultado_esperado/MD5.txt`; si no coincide, conviene comparar cuantos ids tienen en comun.
