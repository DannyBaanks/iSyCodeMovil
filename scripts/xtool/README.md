# IPA desde un checkout Linux

Desde la raíz del proyecto ejecuta `bash scripts/xtool-build-ipa.sh`. Puedes pasar una ruta de salida al final. El resultado es un IPA de dispositivo sin firmar. Se requiere xtool configurado con el SDK Darwin, Swift 6, Python 3, flock, zip y unzip.

El script reconoce el workspace tradicional en `.build/xtool-linux`. Para preparar un workspace nuevo usa `ISYCODE_XTOOL_BOOTSTRAP=1 bash scripts/xtool-build-ipa.sh`. El workspace nuevo vive en `.build/xtool-device` y enlaza las fuentes Swift y C del checkout actual.

La preparación reutiliza la biblioteca de dispositivo y los recursos compilados por Xcode del artefacto de CI `14454715834`, del commit `3c9e26c`. Comprueba el SHA-256 del IPA de entrada y que el catálogo de imágenes, las definiciones de App Intents y la receta de llama.cpp sigan en esa revisión. Obtiene los headers del commit de llama.cpp fijado por esa receta. El ejecutable de la app y el módulo Swift del núcleo se compilan desde el checkout actual.

La primera preparación requiere acceso a GitHub y `gh` con permiso de lectura del artefacto. Los artefactos de Actions caducan. Puedes usar una copia previamente descargada indicando `ISYCODE_CI_IPA=/ruta/IysCodeMovil-unsigned.ipa`; debe coincidir con el hash fijado. Conserva la copia verificada si necesitas repetir la preparación más adelante. Una vez preparados, los insumos se reutilizan localmente. Al modificar los recursos compilados o la versión de llama, genera el nuevo artefacto en Xcode y actualiza el pin antes de usar esta vía. Un workspace tradicional utiliza sus propios insumos.
