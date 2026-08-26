<p align="center">
  <img src="icon.png" width="128" alt="Icono de Verto" />
</p>

<h1 align="center">Verto</h1>

<p align="center">
  <img alt="AI Coded 100%" src="https://img.shields.io/badge/AI%20Coded-100%25-brightgreen?style=flat-square&labelColor=444" />
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=flat-square&labelColor=444&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&labelColor=444&logo=swift&logoColor=white" />
  <a href="../LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-D6A184?style=flat-square&labelColor=444" /></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Español</b>
</p>

<p align="center">Una app nativa de SwiftUI para iOS con traducción de texto, conversaciones bilingües por voz y traducción sobre imágenes de la cámara.</p>

---

## Inicio rápido

1. Abre `Verto.xcodeproj` en Xcode.
2. Selecciona el esquema `Verto`.
3. Elige un simulador de iPhone con iOS 17 o posterior.
4. Pulsa Run.

El proyecto compila sin configuración adicional. Una compilación sin servicio de traducción en línea usa el framework Translation del sistema, que requiere un dispositivo real con iOS 18 o posterior. La traducción del sistema no está disponible en el simulador.

### Traducción en línea

La traducción en línea usa el Cloudflare Worker de `tools/translate-relay` para conectarse a Cloud Translation v3. Despliega el servicio intermedio con [`tools/translate-relay/README.md`](../tools/translate-relay/README.md) y crea la configuración local:

```bash
cp Secrets.local.xcconfig.example Secrets.local.xcconfig
```

Añade el host y el secreto compartido a `Secrets.local.xcconfig`. Git ignora este archivo. Mantén `Secrets.xcconfig`, que sí se incluye en el repositorio, sin credenciales reales.

### Compilación desde la línea de comandos

Si `xcode-select` apunta a las Command Line Tools o a una versión anterior de Xcode, indica qué Xcode debe usarse:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Proyecto

- Proyecto de Xcode: `Verto.xcodeproj`
- Nombre de la app: 译境 en chino simplificado y Verto en los demás idiomas de la interfaz
- Idiomas de la interfaz: chino simplificado, inglés, japonés, coreano y español
- Catálogos de cadenas: `Verto/Localizable.xcstrings` y `Verto/InfoPlist.xcstrings`
- Bundle ID: `com.yspritan.verto`
- Sistema mínimo: iOS 17
- Frameworks principales: SwiftUI, Observation, AVFoundation, PhotosUI, Speech y Translation
- Permisos: la traducción con cámara usa la cámara, las conversaciones por voz usan el micrófono y la ruta de SFSpeechRecognizer también solicita acceso al reconocimiento de voz

La interfaz usa `TabView`, `Form`, `Picker`, `Menu` y semántica de accesibilidad nativos. `AppTheme` y cada pantalla controlan los colores, el espaciado y la disposición exterior. En iOS 26 y posteriores, el sistema muestra Liquid Glass. Las versiones anteriores usan la apariencia nativa correspondiente.

## Funciones e implementación

### Traducción de texto

Toca la tarjeta del texto original para editarla. La propia tarjeta se expande y se contrae, mientras que el editor conserva la misma identidad durante todo el proceso. El texto, el dictado y los cambios de idioma entran primero en un borrador. Toca `Terminar y traducir` para enviarlo. La pantalla de resultados permite intercambiar idiomas, leer en voz alta, copiar, añadir a favoritos y compartir.

Las compilaciones configuradas usan Cloud Translation v3 mediante el servicio intermedio. Las compilaciones sin ese servicio usan la traducción del sistema. Un envío nuevo cancela la solicitud activa y los resultados correctos se guardan en memoria por servicio, par de idiomas y texto original. El idioma de origen admite detección automática. El intercambio de idiomas se activa después de detectar el idioma. Cloud Translation v3 no devuelve traducciones alternativas, por lo que esa acción aparece únicamente cuando otro servicio proporciona alternativas.

### Conversación por voz

La pantalla de voz muestra de forma continua la transcripción activa y una vista previa de la traducción. Los ajustes de separación entre frases se encuentran en [`VoiceTiming`](../Verto/Voice/VoiceTranscription.swift). El flujo de reconocimiento continúa con la frase siguiente después de cada envío, mientras que las traducciones definitivas completan sus burbujas de forma asíncrona. La lectura se reproduce durante las pausas de la conversación y la entrada del micrófono se detiene mientras se reproduce.

La detección bilingüe crea una pista de reconocimiento para cada idioma del par y elige el idioma activo a partir de la probabilidad del idioma, la confianza del reconocimiento y la cantidad de texto. También se puede fijar manualmente uno de los dos idiomas. Las llamadas entrantes, el paso a segundo plano y los cambios de pestaña detienen la captura. La conversación se conserva durante la sesión actual de la app.

En iOS 26 y posteriores, Verto usa SpeechAnalyzer y SpeechTranscriber cuando el sistema los admite. Los demás entornos usan SFSpeechRecognizer. La traducción da prioridad a una sesión de Apple Translation y cambia al mismo servicio que usan las pantallas de texto y cámara cuando esa función del sistema no está disponible.

### Traducción con cámara

La pantalla de cámara permite tomar una foto o cargar una imagen de la fototeca. El reconocimiento de texto se ejecuta en el dispositivo. Cada traducción se coloca sobre el cuadrilátero reconocido y conserva el ángulo, el color de fondo y el color de texto de la imagen. Toca un bloque traducido para comparar el original y la traducción; después puedes copiarlo, leerlo en voz alta o guardarlo en el historial.

Vision proporciona el reconocimiento base del sistema, mientras que el proyecto independiente [`PP-OCR-for-Apple`](https://github.com/YspritanHyzygy/PP-OCR-for-Apple) compila y publica los paquetes de PP-OCRv6. La versión de producción ya no muestra un selector: los dispositivos A12–A13 usan solo Vision; los A14–A16 preparan Equilibrado y después Ligero en el primer inicio; los A17 Pro y posteriores preparan Máxima precisión y después Equilibrado. Las descargas se realizan en segundo plano y en orden. Si no hay un modelo válido, la captura usa Vision inmediatamente. El coreano siempre usa Vision y el modelo Ligero no procesa kana japonés.

Con el idioma de origen en automático, la cámara usa primero Vision rápido y el reconocedor de idiomas del sistema para revisar la escritura. El texto con baja confianza, hangul, escrituras desconocidas o cobertura incompleta se reconoce con Vision preciso. El repositorio también incluye un scheme `OCR Test` que se puede instalar por separado. Solo esa versión permite elegir Automático, Vision o uno de los tres modelos y muestra arriba a la derecha el motor efectivo para la siguiente captura.

Las líneas reconocidas se agrupan en párrafos según la columna, el espaciado, la inclinación y el tamaño de letra. [`TextDetectionPostProcess`](../Verto/Camera/TextDetectionPostProcess.swift) contiene estas reglas. La foto conserva la orientación mostrada en el visor. La copia usada para el reconocimiento sigue `AVCaptureDevice.RotationCoordinator` y los cuadriláteros detectados se transforman de nuevo a las coordenadas de la imagen original.

El texto de la página se deduplica y se traduce por lotes. Los resultados del reconocimiento aparecen primero y cada bloque se actualiza a medida que llegan las traducciones. Los bloques que fallen pueden reintentarse por separado. Al cambiar el par de idiomas se vuelve a traducir la misma foto.

El permiso de cámara se solicita al abrir la pantalla. Si se rechaza, se muestra una explicación y un acceso a los Ajustes del sistema. Cuando no hay ninguna cámara disponible, la pantalla dirige al usuario a la fototeca.

### Idiomas, historial y ajustes

El selector cambia los idiomas de origen y destino y permite buscar por nombre, alias o código de idioma. El historial y los favoritos comparten el mismo almacén de traducciones. Al tocar un elemento del historial, su contenido vuelve a la pantalla de texto.

Ajustes muestra el servicio de traducción efectivo de la compilación actual. También controla la lectura por voz, la lectura automática de la pantalla de texto y la apariencia. La versión de producción administra los modelos OCR automáticamente; solo `OCR Test` muestra los controles de prueba. El modelo propio y la traducción con LLM son elementos desactivados de la hoja de ruta. Las preferencias y el par de idiomas más reciente se guardan en UserDefaults.

### Navegación y movimiento

Texto, voz y cámara son las tres áreas principales de un `TabView` nativo, y cada pestaña conserva su estado. El sistema oculta temporalmente la barra de pestañas durante la edición de texto. Con Reducir movimiento activado, la disposición pasa directamente al estado final y conserva únicamente los cambios de opacidad necesarios.

El movimiento de la tarjeta de texto se aplica a la propia tarjeta. [`TextEntryMotionProfile`](../Verto/Screens/TextTranslateView.swift) contiene sus parámetros. Las pruebas automatizadas verifican la interacción y los estados finales, y las grabaciones de pantalla permiten revisar que la animación sea visible.

## Limitaciones del simulador

- El simulador de iOS no puede ejecutar SpeechTranscriber ni el framework Translation del sistema.
- El simulador no tiene cámara, por lo que el visor, la captura, el flash y la orientación del dispositivo se verifican en un iPhone.
- Vision y el reconocimiento de texto con Core ML pueden ejecutarse en el simulador después de elegir una imagen de la fototeca.
- La traducción sin conexión del sistema, las descargas de modelos de idioma, el reconocimiento de voz con dos pistas, las rutas de auriculares y la respuesta háptica física se verifican en un dispositivo real.

`VertoTests/SpeechAvailabilityProbeTests`, `VertoTests/VisionAvailabilityProbeTests` y `VertoTests/PaddleOCRProbeTests` comprueban las funciones disponibles del sistema. Las sondas informan sobre el entorno actual y los resultados se guardan con los artefactos de prueba.

## Pruebas automatizadas

`VertoUITests` cubre la traducción de texto, los favoritos, la búsqueda de idiomas, las conversaciones por voz, los ajustes de lectura, las superposiciones de cámara, el historial y el estado de las pestañas. `--uitest-canned-translation`, `--uitest-canned-speech`, `--uitest-canned-camera` y `--uitest-reset-settings` proporcionan datos de prueba repetibles. Las pruebas de UI usan servicios inyectados; las rutas reales de red, micrófono, TTS y cámara se verifican por separado.

`LocalizationTests` comprueba los recursos de los cinco idiomas, los marcadores de formato y las reglas de plural. Las pruebas unitarias también cubren el enrutado de traducción, la caché, la máquina de estados de voz, la geometría de OCR y la verificación de los archivos de modelo.

Consulta los simuladores disponibles con `xcrun simctl list devices available` y ejecuta:

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<nombre del dispositivo>' \
  CODE_SIGNING_ALLOWED=NO
```

## Hoja de ruta

El modelo propio de traducción en el dispositivo y la traducción con LLM mediante una clave de API personal siguen planificados y aparecen como opciones desactivadas en Ajustes. El punto de entrada del protocolo para traducción de voz en streaming es [`StreamingSpeechTranslating`](../Verto/Voice/AppleTranslationService.swift). La sesión de voz actual combina reconocimiento de voz, traducción de texto y lectura por voz.

## Licencia

Este proyecto se distribuye bajo la [Apache License 2.0](../LICENSE).
