# PhoneCam

Usa un iPhone (iOS 15+) como webcam para OBS. Tiene resolución, lente, zoom,
temperatura de color y bloqueo de enfoque y exposición. Nada más.

```
iPhone: cámara → H.264 por hardware → MPEG-TS → TCP :5000
PC:     OBS "Fuente multimedia" → tcp://IP-DEL-IPHONE:5000 (decodifica la GPU)
```

En el PC no se instala nada: OBS recibe el video directamente.

---

## 1. Compilar la app (sin Mac, con GitHub)

1. Crea una cuenta en https://github.com y un repositorio nuevo.
   Si es **público**, las compilaciones son gratis e ilimitadas. Si es privado,
   el plan gratis alcanza para unas 40 compilaciones al mes.
2. Sube **todo el contenido** de esta carpeta, incluida la carpeta oculta `.github`.
   Puedes usar `git push` o, en la web, **Add file › Upload files** y arrastrar las carpetas.
3. Abre la pestaña **Actions** del repositorio. La compilación "Build IPA" arranca sola y tarda unos 3–5 minutos.
4. Cuando termine con una ✅, entra a la compilación y descarga **PhoneCam-ipa**
   (es un .zip; adentro está `PhoneCam.ipa`).

## 2. Instalarla en el iPhone (desde Windows)

1. Instala **iTunes** en su versión *de la web de Apple*, no la de Microsoft Store,
   y **Sideloadly** (https://sideloadly.io).
2. Conecta el iPhone por cable y acepta "Confiar en esta computadora".
3. En Sideloadly, arrastra `PhoneCam.ipa`, escribe tu Apple ID y dale a **Start**.
   Puedes usar un Apple ID secundario si prefieres.
4. En el iPhone ve a **Ajustes › General › VPN y gestión de dispositivos**, toca tu Apple ID y selecciona **Confiar**.

> Con un Apple ID gratuito, la app **caduca a los 7 días**. Para renovarla, vuelve a pasarla
> con Sideloadly; tiene una opción de auto-refresh. Tus ajustes no se pierden.

## 3. Configurar OBS con el plugin (recomendado, baja latencia)

El plugin está compilado para **OBS 31.0.0 (64 bits)**.

1. En **Actions**, descarga el artifact **PhoneCam-OBS-plugin** y descomprímelo para obtener `phonecam.dll`.
2. Cierra OBS y copia `phonecam.dll` a `C:\Program Files\obs-studio\obs-plugins\64bit\`.
   Windows te pedirá permiso de administrador.
3. Abre OBS. En **Fuentes**, haz clic en **+** y elige **PhoneCam (iPhone)**.
4. En **Dirección** escribe `127.0.0.1` si usas cable con iproxy, o la IP que muestra la app si usas Wi‑Fi.
   El puerto es `5000`.

El plugin solo se conecta mientras la fuente se ve en la escena. Si la ocultas, el iPhone deja de codificar.

## 3b. Configurar OBS sin plugin (Fuente multimedia)

Funciona, pero con más retraso (~0,7 s), porque la Fuente multimedia agrega su propio búfer.

1. Abre PhoneCam. La primera vez acepta el permiso de cámara.
   En el panel aparece algo como `tcp://192.168.1.50:5000`.
2. En OBS, agrega una fuente **Fuente multimedia** (Media Source) con esta configuración:
   - ☐ **Archivo local**: desmarcado.
   - **Entrada**: `tcp://192.168.1.50:5000`, con la IP que muestra el iPhone.
   - **Formato de entrada**: `mpegts`.
   - **Almacenamiento en búfer de red**: `0 MB`.
   - **Retardo de reconexión**: `1 s`, si tu versión de OBS lo tiene.
   - ☑ **Usar decodificación por hardware cuando esté disponible**.
   - ☐ **Reiniciar la reproducción cuando la fuente se active**: desmarcado.
   - Si tu OBS tiene el campo **Opciones de FFmpeg**, puedes bajar la latencia con:
     `fflags=nobuffer probesize=65536 analyzeduration=200000`
3. Si la imagen sale al revés, clic derecho en la fuente › **Transformar › Rotar 180°**.
   OBS lo hace en la GPU, así que no consume recursos.

El iPhone **solo codifica mientras OBS está conectado**. Si nadie está mirando, casi no gasta batería.

## 4. (Opcional) Por cable USB, con menos latencia y más estabilidad

1. Descarga las herramientas de libimobiledevice para Windows
   (por ejemplo, un release de https://github.com/libimobiledevice-win32/imobiledevice-net).
2. Con el iPhone conectado por cable, ejecuta y deja abierta esta ventana:
   ```
   iproxy 5000 5000
   ```
3. En OBS cambia la entrada a `tcp://127.0.0.1:5000`.

## Consejos

- **1080p · 30 fps** es el mejor equilibrio para un iPhone 7 Plus. 4K funciona, pero calienta el teléfono.
- Usa **Pantalla negra**: apaga la vista previa y baja el brillo al mínimo. Toca la pantalla para volver.
- La app debe quedarse **abierta en primer plano**, porque iOS no permite usar la cámara en segundo plano.
  El bloqueo automático de pantalla ya viene desactivado por la app.
- Déjalo conectado al cargador y, si puedes, sin funda para que se caliente menos.
- Si el balance de blancos manual se ve raro con el lente **Frontal**, déjalo en automático.
  No todos los lentes permiten ajustarlo a mano.
