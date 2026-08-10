<p align="center">
  <img src="icon.png" width="128" alt="Icono de la app 译境" />
</p>

<h1 align="center">译境 (Verto)</h1>

<p align="center">
  <img alt="AI Coded 100%" src="https://img.shields.io/badge/AI%20Coded-100%25-brightgreen?style=flat-square&labelColor=444" />
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=flat-square&labelColor=444&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&labelColor=444&logo=swift&logoColor=white" />
  <a href="../LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-D6A184?style=flat-square&labelColor=444" /></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Español</b>
</p>

<p align="center">Una app de traducción para iOS hecha en SwiftUI nativo — texto, conversación por voz y cámara —<br />con una canalización real de traducción y reconocimiento de voz continuo, que además sirve de campo de pruebas para un modelo de traducción propio y motores de traducción con LLM.</p>

---

## Proyecto

- Proyecto de Xcode: `Verto.xcodeproj`
- Nombre de la app: 译境 (en chino, «el reino de la traducción»); se muestra como «Verto» en idiomas de interfaz distintos del chino
- Idiomas de la interfaz: chino simplificado, inglés, japonés, coreano y español (se puede cambiar por app en Ajustes de iOS; el chino simplificado es el idioma fuente, con catálogos de cadenas en `Verto/Localizable.xcstrings` + `Verto/InfoPlist.xcstrings`)
- Bundle ID: `com.yspritan.verto`
- Sistema mínimo: iOS 17
- Tecnologías: SwiftUI, TabView nativo, Observation, AVFoundation, PhotosUI, Speech (SpeechAnalyzer/SFSpeechRecognizer), Translation; en iOS 26+ la barra de pestañas del sistema adopta Liquid Glass automáticamente.
- Permisos: la conversación por voz necesita el micrófono; la ruta de respaldo de iOS 17–25 necesita además el permiso de reconocimiento de voz (ambas descripciones de uso están en los INFOPLIST_KEY_* del proyecto).

## Características

### Traducción de texto

Al tocar el texto original, la tarjeta real se expande desde su altura de reposo hasta ocupar todo el viewport con un único `.spring(duration: 0.45, bounce: 0.12)`; el teclado en pantalla pide el foco en el siguiente runloop y sube en paralelo con la expansión. Cuando la barra de pestañas se oculta o cambia el área segura del teclado, el resorte redirige su objetivo conservando la velocidad — sin esperar a que el layout se estabilice, sin capas de captura ni fundidos cruzados al terminar. El texto, el dictado y los cambios de idioma se guardan primero como borrador; solo al tocar la marca circular de color terracota «Terminar y traducir» en la esquina superior derecha se confirma y se lanza una traducción real. La vista de resultado permite intercambiar idiomas, leer en voz alta, copiar, marcar como favorito, compartir y ver traducciones alternativas.

**Motor y caché**: la pestaña de texto usa el endpoint gratuito no oficial de Google Translate (`translate.googleapis.com`, `client=gtx`, sin API key). Al enviar se muestra un estado de carga; los fallos muestran un mensaje de error localizado con botón de reintento; un envío nuevo cancela la petición en curso. Los resultados correctos se guardan en una caché LRU en proceso (200 entradas) por motor, par de idiomas y texto original — las traducciones repetidas se sirven de forma síncrona sin tocar la red; los fallos nunca se cachean, así que el reintento siempre sale de verdad. El idioma de origen admite autodetección (`sl=auto`): la barra de idiomas muestra el resultado detectado y el intercambio se habilita solo cuando hay detección; las traducciones de una sola frase incluyen las alternativas que devuelve Google (no disponibles con varias frases; la entrada «alternativas» se oculta cuando no hay).

### Traducción de conversación por voz

Toca el micrófono para empezar a escuchar. Mientras hablas, la burbuja activa muestra la transcripción volátil y una traducción aproximada en vivo con baja opacidad (re-traducción regulada a 350 ms, con texto fuente enmascarado y números de generación que descartan respuestas caducadas para evitar parpadeos). Una frase se cierra automáticamente cuando la transcripción volátil lleva ≥0,9 s estable y el silencio RMS dura ≥0,55 s (o con un toque para terminar manualmente; tope duro de 55 s).

**El reconocimiento nunca espera a la traducción**: el cierre de frase es solo un punto de corte en el flujo de reconocimiento (`finalize(through: nil)`). La frase cerrada aparece en pantalla al instante (vista previa de la traducción aproximada + estado «traduciendo») mientras la traducción definitiva rellena su burbuja de forma asíncrona, con reintento dentro de la burbuja si falla; entre tanto el reconocimiento sigue con la frase siguiente sin perder palabras en la frontera (el estado de las pistas se divide en la línea base de consumo). La lectura automática se encola en los huecos en que nadie habla, y la entrada de audio se suspende durante la reproducción para evitar recapturas.

**Autodetección bilingüe (por defecto)**: el micrófono central identifica automáticamente dentro del par de idiomas — una pista de reconocimiento por idioma recibe el mismo audio en paralelo, y el ganador se elige por puntuación de probabilidad de idioma de NLLanguageRecognizer + confianza del reconocimiento + volumen de texto (con histéresis contra vaivenes por carácter). El idioma detectado decide el lado de la burbuja y la dirección de la traducción, así que puedes mezclar chino e inglés sin costuras; el fallo de una pista no interrumpe la locución (las demás continúan). Toca un botón de idioma para fijar un lado manualmente y otra vez para volver al automático; el área de estado muestra el modo actual («Escuchando · English / 中文», o un solo idioma).

**Pila de reconocimiento**: en iOS 26+ con disponibilidad en runtime (`SpeechTranscriber.isAvailable` y supportedLocales no vacío) usa SpeechAnalyzer con varios módulos SpeechTranscriber conectados (todo en el dispositivo, solo permiso de micrófono; se degrada a una pista si fallan módulos); en caso contrario recurre a varios SFSpeechRecognizer en paralelo (iOS 17–25 y el simulador; ambos permisos).

**Claves de latencia**: la cadena de reconocimiento persiste a nivel de sesión — el analyzer se construye en prepare con residencia de modelo `.processLifetime` y precalentamiento `prepareToAnalyze`; entre frases se corta con `finalize(through: nil)` en vez de destruir y reconstruir (reconstruir = pagar una carga de modelo de segundos por cada frase); el semidúplex durante la reproducción TTS y los huecos entre frases se mantiene haciendo que la fuente de audio suspendida descarte búferes (sin ciclos setActive de la sesión de audio por frase); `.fastResults` acelera la primera transcripción volátil; los umbrales de cierre son 0,9 s de volátil estable + 0,55 s de silencio; la elección del ganador puede cambiar libremente sin histéresis durante los primeros 0,7 s de habla.

**Enrutado de traducción**: primero el framework Translation de Apple — en iOS 26+ construye directamente `Translation.TranslationSession(installedSource:target:)` (en 26.4+ una sesión aparte con estrategia `.lowLatency` atiende los parciales); en iOS 18–25 las sesiones se toman prestadas a través de una vista anfitriona residente en la raíz de AppShell. En el simulador / iOS 17 / sin paquetes de idioma / con errores del framework, cae automáticamente al endpoint de Google y recuerda la decisión por par de idiomas (motivos registrados con os.Logger).

Las llamadas entrantes, pasar a segundo plano y cambiar de pestaña detienen la captura; la conversación persiste entre pestañas (el controller pertenece a AppShell). Las burbujas llevan botón de lectura; la cabecera de la página tiene un menú rápido de modo de lectura (sincronizado con Ajustes); la «autodetección» del par se resuelve a un idioma concreto en la pestaña de voz según el idioma del lado contrario. Las traducciones finales se cachean en proceso (solo finales — los parciales nunca entran en la LRU); una final fallida puede reintentarse en su burbuja. La forma de onda se alimenta del nivel real del micrófono (vDSP RMS).

### Traducción con cámara

Selección de fotos, estado de carga del reconocimiento, tarjetas superpuestas de traducción de menús, estados de flash y exposición.

### Idiomas, historial y favoritos

- Selector de idiomas: intercambio origen/destino, búsqueda por nombre/alias/código, estados de selección y de resultado vacío.
- Historial y favoritos: registros de traducción compartidos, filtro de favoritos, alternado instantáneo de estrella, tocar un registro lo rellena en la pestaña de texto.

### Ajustes y apariencia

La hoja de ajustes se abre desde la esquina superior derecha de la pestaña de texto. El modelo de traducción es conmutable — Google Translate (gratuito) está disponible hoy, mientras que el modelo propio y la traducción con LLM (con tu propia API key) aparecen como marcadores deshabilitados «próximamente». La sección «conversación por voz» elige el comportamiento de lectura de las traducciones (solo texto / leer tras traducir / leer solo con auriculares — con cable, Bluetooth y USB, con detección de ruta en tiempo real); las preferencias generales incluyen «leer traducciones automáticamente» (solo pestaña de texto). Motor, modo de lectura, preferencias y el último par de idiomas persisten en UserDefaults; el primer arranque conserva el contenido de demostración y después la app empieza en blanco con el par recordado.

**Modo oscuro**: seguir al sistema o fijar la apariencia manualmente en Ajustes; la paleta adaptativa recorre todas las pantallas y componentes.

### Navegación y animaciones

- Texto, voz y cámara son las tres áreas de nivel superior de un TabView nativo; en uso normal la barra de pestañas permanece visible y cada pestaña conserva su estado — solo se oculta temporalmente por el sistema durante la escritura enfocada en la pestaña de texto, y vuelve tras confirmar el borrador. iOS 26+ muestra Liquid Glass a través del sistema, iOS 17–25 usa la apariencia de barra correspondiente; un cambio real de selection dispara la respuesta háptica del sistema.
- La escritura enfocada no coloca ningún «Hecho» en la barra del `.keyboard`; tanto el teclado en pantalla como el físico usan el botón de envío fijado en la esquina superior derecha, evitando que las acciones inferiores choquen con la barra de pestañas.
- La transición de escritura tiene una única fuente de verdad: si existe borrador. El editor del texto original mantiene una sola identidad todo el tiempo; expandir y recoger son animaciones de layout sobre la tarjeta real (el árbol de render interpola el frame de cada vista fotograma a fotograma, y la Shape de la cara de la tarjeta recalcula su path en cada fotograma para que el radio continuo de 22 pt no se deforme) — sin mediciones de geometría, sin validaciones entre transacciones, sin coreografía por fases. La transición es interactiva e interrumpible de principio a fin; tocar la marca a mitad de expansión la invierte suavemente con la velocidad actual. El área de resultados se desvanece bajo el papel con una transición de opacidad de ~0,16 s, con su posición arrastrada por el resorte del layout; la marca rebota de 0,84× a su tamaño original tras ~40 ms de retardo.
- Con «Reducir movimiento» activado, el layout salta directamente a su estado final (sin animaciones de tamaño, posición ni escala); el área de resultados y los botones de cabecera conservan solo un fundido de opacidad de ~0,12 s; el teclado y la barra de pestañas siguen el comportamiento del sistema.

## Estado y hoja de ruta

La traducción de texto usa el endpoint gratuito no oficial de Google (requiere red con acceso a los servicios de Google); la conversación por voz es una canalización real de reconocimiento + traducción (ver arriba); el OCR de menús usa por ahora datos de demostración locales. El modelo propio y los motores de traducción basados en LLM están planificados y aparecen como marcadores en Ajustes — la costura para un futuro motor de traducción de voz en streaming ya está dejada al final de `Verto/Voice/AppleTranslationService.swift` (un stub del protocolo `StreamingSpeechTranslating`, conectado en la capa de sesión de voz y no en la capa texto→texto).

## Ejecutar en Xcode

1. Abre `Verto.xcodeproj` en Xcode.
2. Elige el esquema `Verto`.
3. Elige cualquier simulador de iPhone con iOS 17 o superior.
4. Pulsa Run.

Si el `xcode-select` de tu terminal apunta a las Command Line Tools o a un Xcode antiguo, antepon `DEVELOPER_DIR` para compilar desde la línea de comandos:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/VertoDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Limitaciones del simulador

**Restricciones oficiales de Apple, verificadas empíricamente**: ni SpeechTranscriber ni el framework Translation funcionan en el simulador de iOS (sin ANE, sin modelos de traducción). Allí la pestaña de voz cae automáticamente a la cadena SFSpeechRecognizer + respaldo de Google, y según lo medido en el simulador de iOS 27: **en-US no puede inicializarse porque el sistema fuerza el reconocedor local (kLSRErrorDomain 300, falla tanto en modo local como servidor), mientras que zh-CN funciona por completo con reconocimiento en servidor** — así que hablando chino en el simulador se recorre de verdad el ciclo «reconocer → traducir → leer», y el inglés lo salta en silencio la autodetección multipista (con una sola pista de inglés se muestra el aviso «El simulador no puede reconocer este idioma. Pruébalo en un dispositivo real.»).

El diagnóstico puede repetirse en cualquier momento con `VertoTests/SpeechAvailabilityProbeTests` (informe en /private/tmp/speech-availability-probe.txt). La ruta SpeechAnalyzer, la traducción offline del sistema, la descarga de modelos de idioma, la estrategia `.lowLatency`, el comportamiento de doble pista en dispositivo y la detección de auriculares solo pueden verificarse en hardware real. Las pruebas de UI inyectan reconocimiento guionizado y TTS silencioso con `--uitest-canned-speech`, sin tocar nunca audio real.

## Pruebas automatizadas

El proyecto incluye el target de pruebas de UI `VertoUITests`, cuyos flujos de aceptación cubren traducción de texto y favoritos, búsqueda y selección de idiomas, el flujo completo de voz (reposo → escucha → burbuja confirmada → pausa), la selección del modo de lectura en Ajustes, resultados de reconocimiento de cámara, cambio entre pestañas del TabView nativo / sincronización de selección / retención de estado, «borrador → Terminar y traducir → vista de resultado restaurada», y la regresión del estado final con «Reducir movimiento» en DEBUG.

Las pruebas de UI se lanzan siempre con `--uitest-canned-translation`, `--uitest-canned-speech` y `--uitest-reset-settings`: los dos primeros inyectan traducciones de demostración fijas y reconocimiento de voz guionizado (sin red real, sin micrófono ni TTS), y el último restablece las preferencias persistidas para que las aserciones sean estables.

La interfaz está localizada y las pruebas se ejecutan fijadas al chino simplificado: la Test action del scheme compartido establece `zh-Hans` (lo que cubre las pruebas unitarias alojadas en la app), y las pruebas de UI pasan además `-AppleLanguages` explícitamente, de modo que las aserciones sobre textos en chino no dependen del idioma del simulador; `LocalizationTests` y una prueba de humo con la interfaz en inglés verifican la integridad y la carga real de los recursos de cada idioma.

Las pruebas unitarias cubren la máquina de estados del controlador de conversación (regulación, descarte por generación caducada, temporización de cierres, la matriz de compuertas del TTS, reintentos tras fallo, aciertos de caché, etc.), la cadena de respaldo del enrutado de traducción, la persistencia del modo de lectura y el mapeo de locales. Las pruebas automatizadas de la transición de entrada de texto solo verifican la entrada y la salida del modo de edición y el estado final estable; la visibilidad, los saltos y las imágenes fantasma se validan revisando una grabación real de la pantalla del simulador de iPhone.

Puede ejecutarse en cualquier simulador de iPhone instalado; por ejemplo:

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/VertoTestData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:VertoUITests
```

El simulador puede verificar que la selection cambia de verdad, pero no la vibración física; la intensidad y la sensación hápticas necesitan una comprobación final en un iPhone real.

## Licencia

Este proyecto se distribuye bajo la [Apache License 2.0](../LICENSE).
