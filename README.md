# PhoneCam

Usa un iPhone como webcam para OBS, con baja latencia y el menor consumo posible en el PC.
La misma app sirve para un iPhone viejo (iOS 15, por ejemplo un 7 Plus) y para uno nuevo (por ejemplo un 17 Pro).

- **Cámara:** resolución hasta 4K · 60 fps, lentes (0.5x · 1x · 2x · 4x · Frontal, según el iPhone), zoom,
  enfoque automático o manual, compensación de exposición, balance de blancos y modos vertical y espejo.
- **Control desde OBS:** todos esos ajustes también se pueden cambiar desde las propiedades de la fuente.
- **Latencia:** unos 100–200 ms con el plugin, parecido a Camo.
- **Consumo:** el iPhone codifica por hardware y el PC decodifica con la GPU. No hay programas en segundo plano
  ni cámara virtual. Si la fuente no se ve en OBS, nada trabaja.

## Cómo funciona

```
iPhone (PhoneCam)                                  PC (OBS)
cámara → H.264 por hardware ──┬── cable (iproxy) ─┬─→ plugin "PhoneCam (iPhone)"   ← recomendado
                              └── Wi‑Fi ──────────┘     decodifica con la GPU, sin búfer
                                                    └─→ "Fuente multimedia" (MPEG-TS) ← sin plugin, ~0,7 s de retraso
```

El iPhone escucha en el puerto **5000**. Si el que se conecta es el plugin, envía video directo y recibe los
ajustes de OBS. Si es la Fuente multimedia, envía MPEG-TS.

---

## 1. Compilar (sin Mac, con GitHub Actions)

Cada `push` al repositorio compila las dos piezas en unos 5 minutos:

| Artifact | Qué es | Dónde se compila |
|---|---|---|
| **PhoneCam-ipa** | La app del iPhone, sin firmar | Mac de GitHub (`macos-15`) |
| **PhoneCam-OBS-plugin** | `phonecam.dll` para **OBS 31.0.0 (64 bits)** | Windows de GitHub |

Para descargarlos, entra a **Actions**, abre la compilación más reciente con ✅ y bájalos de **Artifacts**,
con tu sesión de GitHub iniciada. **Fíjate de bajar los dos de la misma compilación:** todas las compilaciones
tienen artifacts con el mismo nombre. Cuando actualices, actualiza la app y el plugin juntos.

## 2. Instalar la app en el iPhone (desde Windows)

iOS solo abre apps firmadas. Sin cuenta de desarrollador paga, la firmas con tu Apple ID usando la cuenta de
desarrollador gratuita de Apple, que es una función oficial.

**Requisitos en el PC:** **iTunes** e **iCloud** en su versión *de la web de Apple*, no la de Microsoft Store.
No hace falta iniciar sesión en ellos.

### Opción A: Sideloadly
1. Instala Sideloadly desde https://sideloadly.io.
2. Conecta el iPhone por cable y acepta "Confiar en esta computadora".
3. Arrastra `PhoneCam.ipa`, escribe un Apple ID y presiona **Start**.
4. En las opciones avanzadas, **no** marques "cambiar Bundle ID", porque gasta App IDs (ver más abajo).

### Opción B: AltStore (código abierto, se renueva solo)
1. Instala **AltServer** desde https://altstore.io. Queda como un ícono con forma de rombo junto al reloj.
2. Con el iPhone por cable, haz clic en el rombo, elige **Install AltStore** y selecciona tu iPhone.
3. Pasa `PhoneCam.ipa` al iPhone, por ejemplo por iCloud Drive. En AltStore ve a **My Apps**, toca **+** y elige el archivo.
4. Con AltServer abierto y el iPhone en la misma Wi‑Fi, AltStore renueva la app sola antes de que caduque.

### En el iPhone (las dos opciones)
1. Ve a **Ajustes › General › VPN y gestión de dispositivos**, toca el Apple ID y elige **Confiar**.
2. En **iOS 16 o posterior**, activa **Ajustes › Privacidad y seguridad › Modo desarrollador** y reinicia.
   Al desbloquear, confirma con **Activar**. La opción aparece recién después de instalar la app por primera vez.
   Es una función oficial de Apple: no afecta la garantía y se puede apagar cuando quieras.

### Límites y consejos
- Con un Apple ID gratuito, la app **caduca a los 7 días**. Hay que volver a instalarla o dejar que AltStore la renueve.
  Tus ajustes se conservan.
- Apple permite **10 App IDs cada 7 días** y **3 apps a la vez por iPhone**. PhoneCam usa un solo App ID
  (`com.phonecam.app`), incluso al renovar o al instalarla en varios iPhone.
- **Apple ID secundario:** recomendable si el iPhone es el principal. Solo se usa para firmar y nunca se inicia
  sesión con él en el teléfono. Puede usar el mismo número de teléfono que tu cuenta principal.
- **Error `-80046` "This action cannot be completed at this time":** Apple está rechazando el inicio de sesión.
  Suele ser un bloqueo temporal por varios intentos seguidos o porque la cuenta es nueva.
  **Deja de intentar**, espera unas horas (hasta 24 h) y prueba una sola vez.
  Si la cuenta es nueva, entra antes una vez a icloud.com con ella y acepta los términos.
- **Cuenta de desarrollador paga (99 USD/año):** la app dura un año y se puede instalar con TestFlight,
  sin Sideloadly ni AltStore.

## 3. OBS con el plugin (recomendado)

1. Cierra OBS y copia `phonecam.dll` a `C:\Program Files\obs-studio\obs-plugins\64bit\`.
   Windows pide permiso de administrador.
2. Abre OBS. En **Fuentes**, haz clic en **+** y elige **PhoneCam (iPhone)**.
3. En **Dirección** escribe `127.0.0.1` si usas cable (ver sección 5) o la IP que muestra la app si usas Wi‑Fi.
   El puerto es `5000`.

En las propiedades de la fuente:

| Grupo | Ajustes |
|---|---|
| **Cámara** | Resolución, lente, zoom, vertical (9:16), espejo, balance de blancos automático o en Kelvin |
| **Enfoque** | Automático, o manual con distancia de 0 (cerca) a 100 (lejos) |
| **Exposición** | Compensación de −3 a +3 EV y bloqueo |
| **Conexión** | Dirección, puerto y "Decodificar con la GPU" |

- **OBS manda:** al conectarse, el iPhone toma los ajustes guardados en la escena. Si cambias algo en el teléfono,
  también queda guardado en OBS; lo verás la próxima vez que abras las propiedades.
- **El 2x de los iPhones nuevos** se consigue con **Normal (1x)** y **Zoom 2,0**.
- Si eliges un lente que el iPhone no tiene, usa el normal. Si eliges una resolución o unos fps que no soporta,
  usa lo más cercano.
- **GPU:** usa D3D11VA y, si no está disponible, la CPU. El registro de OBS
  (**Ayuda › Archivos de registro**) dice `[phonecam] decodificando por GPU (d3d11va)` o `por CPU`.
- El plugin solo se conecta mientras la fuente se ve en alguna escena.
- Al cambiar entre vertical y horizontal cambia la forma de la fuente. Para acomodarla, haz clic derecho y elige
  **Transformar › Ajustar a la pantalla**. No uses los giros o volteos de OBS para esto: lo hace la app.

## 4. OBS sin plugin (Fuente multimedia)

Funciona con cualquier versión de OBS, pero con ~0,7 s de retraso, porque la Fuente multimedia agrega su propio
búfer, que no se puede desactivar. Los ajustes se cambian solo desde el iPhone.

Agrega una **Fuente multimedia** con:
- ☐ **Archivo local** desmarcado.
- **Entrada:** `tcp://IP-DEL-IPHONE:5000` (o `tcp://127.0.0.1:5000` por cable).
- **Formato de entrada:** `mpegts`.
- **Almacenamiento en búfer de red:** `0 MB`.
- ☐ **Reiniciar la reproducción cuando la fuente se active** desmarcado.

## 5. Por cable USB (opcional)

Por cable no dependes del Wi‑Fi. Funciona igual con Lightning y con USB‑C.

1. Descarga libimobiledevice para Windows
   (por ejemplo, un release de https://github.com/libimobiledevice-win32/imobiledevice-net).
2. Con el iPhone conectado, ejecuta `iproxy 5000 5000` y deja la ventana abierta.
3. En OBS usa la dirección `127.0.0.1`.

**Para que arranque solo y oculto con Windows:** crea `PhoneCam-iproxy.vbs` en la carpeta de inicio
(**Win + R** › `shell:startup`), con la ruta donde descomprimiste libimobiledevice:

```vb
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "C:\ruta\a\libimobiledevice"
sh.Run """C:\ruta\a\libimobiledevice\iproxy.exe"" 5000 5000", 0, False
```

Si cambias esa carpeta de lugar, actualiza la ruta. `iproxy` se conecta a un solo iPhone a la vez: si tienes dos,
usa uno por cable y el otro por Wi‑Fi, cada uno con su propia fuente en OBS.

## 6. Usar la app

Los controles están abajo y son compactos, como en la app Cámara, para que se vea lo que se filma:

- **Arriba:** el estado de la conexión. Mientras espera a OBS, muestra la dirección.
- **Fila de lentes:** el activo se ve en amarillo.
- **Barra de íconos:** **Zoom · Foco · Luz · Color · Video** abren encima solo ese control; un segundo toque lo cierra.
  **Vertical** y **Espejo** se encienden en amarillo. **Negra** apaga la vista previa y baja el brillo al mínimo;
  se sale tocando la pantalla.
- **Tocar la imagen** oculta o muestra todos los controles.
- **Video** muestra la resolución, la dirección `tcp://…` y el estado de la cámara.

| | iPhone 7 Plus (iOS 15) | iPhone 17 Pro |
|---|---|---|
| Lentes | 1x · 2x · Frontal | 0.5x · 1x · 2x (recorte del sensor de 48 MP) · 4x · Frontal |
| Máximo | 4K · 30 fps | 4K · 60 fps |
| Recomendado | 1080p · 30 fps | 1080p · 60 fps |

## Consejos

- Si tu transmisión sale en 1080p, usa **1080p** también en la cámara. El 4K no se nota y pesa más en el PC,
  sobre todo a 60 fps.
- La app tiene que estar **abierta en primer plano**, porque iOS no permite usar la cámara en segundo plano.
  El bloqueo automático de pantalla ya viene desactivado por la app.
- El iPhone **solo codifica mientras OBS está conectado**: si nadie está mirando, casi no gasta batería.
- Déjalo conectado al cargador y, si puedes, sin funda, para que se caliente menos.
- **Imagen quemada:** baja la exposición (EV) en **Luz**. **Foco que salta** al mover las manos: en **Foco**,
  desactiva el automático y ajusta la distancia.
- La cámara frontal del 7 Plus y de otros modelos tiene foco fijo, así que ahí el foco manual no hace nada.
