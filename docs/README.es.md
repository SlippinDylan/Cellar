<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Icono de Cellar">
  <h1>Cellar</h1>
  <p>Gestiona las herramientas de desarrollo de tu Mac en una sola app nativa.</p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <strong>Español</strong>
  </p>
</div>

Cellar reúne el software de Homebrew, los paquetes globales de npm, las versiones de Node.js y la configuración del terminal en una sola app para macOS. Consulta lo que tienes instalado, encuentra las herramientas que necesitas, actualízalas y revisa qué se eliminará antes de desinstalar.

> [!NOTE]
> Cellar 1.0 todavía no se ha publicado. Aún no hay un instalador descargable ni un Cask de Homebrew. Puedes compilar la app desde el código fuente; siguen pendientes las comprobaciones en un entorno real y la validación de la interfaz.

## Qué puedes hacer

| Tarea | En Cellar |
|---|---|
| Comprobar tu entorno | Consulta el estado de Homebrew, Node.js, npm, nvm y el terminal en la página de inicio. |
| Gestionar el software instalado | Explora, busca y filtra Formulae y Casks de Homebrew y paquetes globales de npm en la biblioteca. Actualiza elementos individuales o un lote filtrado, y desinstala elementos individualmente. |
| Encontrar nuevas herramientas | Busca en Homebrew y npm desde la página de descubrimiento e instala un elemento o un lote de paquetes del mismo tipo. |
| Configurar tu entorno | Gestiona versiones globales de Node.js con nvm, taps de Homebrew, registros de npm y temas y complementos de Oh My Zsh. |
| Comprobar y limpiar | Ejecuta los diagnósticos de Homebrew y la verificación de la caché de npm, y revisa las tareas de limpieza admitidas para cachés, versiones de Node sin usar y registros antiguos de Manager. |

El progreso de las tareas y sus resultados recientes siguen visibles al cambiar de página, incluidos los resultados individuales cuando un lote solo se completa parcialmente.

La interfaz admite **inglés, chino simplificado, chino tradicional, japonés, coreano, alemán, francés y español**. La opción predeterminada es **Seguir el sistema**. Puedes elegir un idioma en Ajustes > General; al cambiarlo, Cellar se reinicia.

## Requisitos y disponibilidad

- **macOS 26 o posterior**, en un **Mac con chip de Apple** (`arm64`).
- **Xcode 26 o posterior** para compilar desde el código fuente.
- Homebrew, Node.js, npm y nvm son herramientas que gestiona Cellar; no se incluyen con la app.

Si faltan las Command Line Tools o Homebrew, Cellar puede abrir el proceso de instalación del sistema. El paquete de instalación oficial de Homebrew se verifica antes de abrirlo. Para nvm, Cellar ofrece instrucciones de instalación.

Sparkle está configurado para actualizar la app mediante el [tap de Homebrew compartido](https://github.com/SlippinDylan/homebrew-tap). La fuente de actualizaciones firmada y el Cask se crearán con la primera publicación correspondiente. Las actualizaciones de la app están desactivadas en las compilaciones Debug y las compilaciones locales habituales.

## Compilar desde el código fuente

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

En Xcode, selecciona el esquema **Cellar**, **My Mac** y la configuración **Debug**, y pulsa **⌘R**. Debug utiliza una firma ad hoc local (Sign to Run Locally), por lo que no necesitas iniciar sesión con una cuenta de desarrollador de Apple ni instalar un certificado de firma.

Para compilar desde la línea de comandos:

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

La app compilada se encuentra en `build/DerivedData-Debug/Build/Products/Debug/Cellar.app`. Consulta la [guía de desarrollo](development.md) para obtener información sobre pruebas, firmas y compilaciones Release.

## Antes de modificar tu entorno

- Los paquetes globales de npm pertenecen a una instalación concreta de Node.js. Las búsquedas y operaciones utilizan el entorno Node seleccionado; Cellar no gestiona las dependencias npm locales de los proyectos.
- La búsqueda y los cambios de paquetes npm requieren una instalación de nvm compatible; las demás instalaciones de Node detectadas siguen siendo legibles. La configuración de usuario del registro y el mantenimiento de caché conservan sus propios requisitos. Las URL del registro admiten HTTPS sin credenciales y HTTP local en `localhost`, `127.0.0.1` o `[::1]`; no se admiten otras direcciones HTTP.
- Cambiar la versión de Node que utiliza Cellar solo afecta a la sesión actual de Cellar, no a los terminales que ya están abiertos. Cellar gestiona entornos globales de Node/npm y no archivos `.nvmrc` por proyecto.
- Las instalaciones y actualizaciones individuales de paquetes desde las tarjetas de la biblioteca y de la página de descubrimiento se inician directamente. La instalación de componentes del terminal, las operaciones por lotes, las desinstalaciones, las limpiezas y los cambios de configuración requieren confirmar su alcance. No se pueden detener manualmente las tareas en curso, y Cellar impide salir de la app mientras haya tareas activas.
- La desinstalación de Casks de Homebrew también puede eliminar datos asociados confirmados previamente y cuya pertenencia al objetivo se pueda verificar. Los datos compartidos o no verificados se conservan. Las desinstalaciones de Formulae y de paquetes npm no incluyen esta limpieza de datos asociados. Cellar no ejecuta Homebrew cleanup ni elimina automáticamente dependencias huérfanas.
- La limpieza de algunos archivos residuales requiere autorización de administrador de macOS o acceso total al disco. macOS gestiona las contraseñas; Cellar no las recopila ni instala un servicio privilegiado permanente. La autorización no garantiza que se puedan eliminar todos los archivos.
- Las operaciones pueden completarse parcialmente. Cellar informa de los elementos completados y fallidos, sin garantizar la reversión de los cambios. No modifica `.zprofile` ni cambia tu shell de inicio de sesión.

## Datos y red

Cellar no tiene cuentas de usuario, telemetría ni servidores propios. Las consultas de herramientas, búsquedas, instalaciones, complementos y actualizaciones de la app contactan con servicios oficiales o con las fuentes que configures. Las consultas de Homebrew y npm también pueden escribir en sus propias cachés.

Los iconos de los Casks oficiales de Homebrew proceden de [CaskFlow](https://github.com/alielsokary/CaskFlow) a través de `cdn.jsdelivr.net`. La CDN recibe el identificador del Cask solicitado y los datos habituales de conexión. La licencia MIT de CaskFlow se incluye con la app; los logotipos de software siguen siendo propiedad de sus respectivos titulares.

| Datos locales | Ubicación |
|---|---|
| Copias de ejecución de los Managers incluidos con la app | `~/Library/Application Support/Cellar/Managers/<version>/` |
| Registros | `~/Library/Logs/Cellar/` |
| Iconos de software descargados | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

El nivel de registro y el periodo de conservación se configuran en Ajustes > General. Los archivos de registro no contienen los comandos sin procesar ni sus salidas stdout/stderr. Los resultados de las tareas solo se conservan durante la sesión actual.

## Documentación

Los documentos detallados del proyecto están actualmente en chino: [índice de documentación](README.md), [requisitos del producto](requirements/product-requirements.md), [arquitectura](architecture/macos-app-architecture.md), [guía de desarrollo](development.md) y [lista de comprobaciones manuales](manual-smoke-checklist.md).
