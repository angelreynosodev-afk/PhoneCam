/*
 * PhoneCam: fuente de OBS que recibe el video del iPhone con la menor latencia posible
 * y permite controlar la cámara desde las propiedades de la fuente.
 *
 * Protocolo (TCP):
 *   PC -> iPhone: "PCAM1\n" al conectar, luego líneas JSON con los ajustes de la cámara.
 *   iPhone -> PC: [u32 BE largo][u64 BE pts en µs][u8 flags][payload]
 *                 flags & 0x01: keyframe · flags & 0x80: mensaje de estado JSON (no es video)
 *
 * A diferencia de la "Fuente multimedia", aquí no hay reloj de reproducción ni búfer:
 * el decoder corre con LOW_DELAY (por GPU con D3D11VA si está disponible) y cada frame
 * se entrega a OBS apenas se decodifica (fuente async "unbuffered").
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <obs-module.h>
#include <util/platform.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

OBS_DECLARE_MODULE()

MODULE_EXPORT const char *obs_module_description(void)
{
	return "PhoneCam: iPhone como webcam con baja latencia";
}

#define HEADER_SIZE 13
#define MAX_FRAME (16 * 1024 * 1024)
#define FLAG_KEY 0x01
#define FLAG_STATE 0x80

struct phonecam {
	obs_source_t *source;
	HANDLE thread;
	volatile LONG stop;
	volatile LONG reconnect;

	SRWLOCK lock; /* protege todo lo de abajo */
	char host[256];
	int port;
	bool hw_decode;
	char ctl[512]; /* último JSON de ajustes, terminado en '\n' */
	SOCKET sock;
};

/* ------------------------------------------------------------------------- */
/* Red                                                                       */

static void wait_ms(struct phonecam *pc, int ms)
{
	for (int t = 0; t < ms && !pc->stop && !pc->reconnect; t += 50)
		Sleep(50);
}

static SOCKET connect_to(const char *host, int port)
{
	char portstr[16];
	snprintf(portstr, sizeof(portstr), "%d", port);

	struct addrinfo hints = {0};
	struct addrinfo *res = NULL;
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res)
		return INVALID_SOCKET;

	SOCKET s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
	if (s == INVALID_SOCKET) {
		freeaddrinfo(res);
		return INVALID_SOCKET;
	}

	/* connect no bloqueante con timeout de 2 s */
	u_long nb = 1;
	ioctlsocket(s, FIONBIO, &nb);
	int r = connect(s, res->ai_addr, (int)res->ai_addrlen);
	freeaddrinfo(res);

	if (r == SOCKET_ERROR) {
		if (WSAGetLastError() != WSAEWOULDBLOCK) {
			closesocket(s);
			return INVALID_SOCKET;
		}
		fd_set wfds, efds;
		FD_ZERO(&wfds);
		FD_ZERO(&efds);
		FD_SET(s, &wfds);
		FD_SET(s, &efds);
		struct timeval tv = {2, 0};
		if (select(0, NULL, &wfds, &efds, &tv) <= 0 || FD_ISSET(s, &efds)) {
			closesocket(s);
			return INVALID_SOCKET;
		}
	}

	nb = 0;
	ioctlsocket(s, FIONBIO, &nb);
	BOOL one = TRUE;
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one));
	DWORD timeout = 3000; /* si el iPhone deja de mandar 3 s, reconectar */
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
	return s;
}

static bool recv_all(struct phonecam *pc, SOCKET s, uint8_t *buf, int len)
{
	int got = 0;
	while (got < len) {
		if (pc->stop || pc->reconnect)
			return false;
		int r = recv(s, (char *)buf + got, len - got, 0);
		if (r <= 0)
			return false;
		got += r;
	}
	return true;
}

/* Llamar con pc->lock tomado en modo exclusivo. */
static void send_ctl_locked(struct phonecam *pc)
{
	if (pc->sock != INVALID_SOCKET && pc->ctl[0])
		send(pc->sock, pc->ctl, (int)strlen(pc->ctl), 0);
}

/* ------------------------------------------------------------------------- */
/* Ajustes de cámara <-> JSON                                                */

static void build_ctl(obs_data_t *settings, char *out, size_t size)
{
	/* Los decimales viajan como enteros (centésimas/décimas) para no depender
	 * del separador decimal del sistema. */
	int zoom100 = (int)floor(obs_data_get_double(settings, "zoom") * 100.0 + 0.5);
	int ev10 = (int)floor(obs_data_get_double(settings, "ev") * 10.0 + 0.5);
	snprintf(out, size,
		 "{\"mode\":\"%s\",\"lens\":\"%s\",\"zoom100\":%d,\"wbAuto\":%s,\"temp\":%d,"
		 "\"afAuto\":%s,\"focus100\":%d,\"ev10\":%d,\"aeLock\":%s}\n",
		 obs_data_get_string(settings, "mode"), obs_data_get_string(settings, "lens"), zoom100,
		 obs_data_get_bool(settings, "wb_auto") ? "true" : "false", (int)obs_data_get_int(settings, "temp"),
		 obs_data_get_bool(settings, "af_auto") ? "true" : "false", (int)obs_data_get_int(settings, "focus"),
		 ev10, obs_data_get_bool(settings, "ae_lock") ? "true" : "false");
}

struct state_task {
	obs_weak_source_t *weak;
	obs_data_t *state;
};

/* Corre en el hilo de la UI: guarda en la fuente lo que se cambió desde el iPhone. */
static void apply_state_task(void *param)
{
	struct state_task *t = param;
	obs_source_t *src = obs_weak_source_get_source(t->weak);
	if (src) {
		obs_data_t *s = obs_source_get_settings(src);
		obs_data_t *st = t->state;
		if (obs_data_has_user_value(st, "mode"))
			obs_data_set_string(s, "mode", obs_data_get_string(st, "mode"));
		if (obs_data_has_user_value(st, "lens"))
			obs_data_set_string(s, "lens", obs_data_get_string(st, "lens"));
		if (obs_data_has_user_value(st, "zoom100"))
			obs_data_set_double(s, "zoom", (double)obs_data_get_int(st, "zoom100") / 100.0);
		if (obs_data_has_user_value(st, "wbAuto"))
			obs_data_set_bool(s, "wb_auto", obs_data_get_bool(st, "wbAuto"));
		if (obs_data_has_user_value(st, "temp"))
			obs_data_set_int(s, "temp", obs_data_get_int(st, "temp"));
		if (obs_data_has_user_value(st, "afAuto"))
			obs_data_set_bool(s, "af_auto", obs_data_get_bool(st, "afAuto"));
		if (obs_data_has_user_value(st, "focus100"))
			obs_data_set_int(s, "focus", obs_data_get_int(st, "focus100"));
		if (obs_data_has_user_value(st, "ev10"))
			obs_data_set_double(s, "ev", (double)obs_data_get_int(st, "ev10") / 10.0);
		if (obs_data_has_user_value(st, "aeLock"))
			obs_data_set_bool(s, "ae_lock", obs_data_get_bool(st, "aeLock"));
		obs_data_release(s);
		obs_source_release(src);
	}
	obs_data_release(t->state);
	obs_weak_source_release(t->weak);
	bfree(t);
}

static void handle_state(struct phonecam *pc, const uint8_t *json, int len)
{
	char *str = bmalloc((size_t)len + 1);
	memcpy(str, json, (size_t)len);
	str[len] = 0;
	obs_data_t *state = obs_data_create_from_json(str);
	bfree(str);
	if (!state)
		return;

	struct state_task *t = bzalloc(sizeof(struct state_task));
	t->weak = obs_source_get_weak_source(pc->source);
	t->state = state;
	obs_queue_task(OBS_TASK_UI, apply_state_task, t, false);
}

/* ------------------------------------------------------------------------- */
/* Decodificación                                                            */

static void output_frame(struct phonecam *pc, const AVFrame *f)
{
	enum video_format fmt;
	switch (f->format) {
	case AV_PIX_FMT_YUV420P:
	case AV_PIX_FMT_YUVJ420P:
		fmt = VIDEO_FORMAT_I420;
		break;
	case AV_PIX_FMT_NV12:
		fmt = VIDEO_FORMAT_NV12;
		break;
	default:
		return;
	}

	bool full = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P;
	enum video_colorspace cs = (f->colorspace == AVCOL_SPC_BT470BG || f->colorspace == AVCOL_SPC_SMPTE170M)
					   ? VIDEO_CS_601
					   : VIDEO_CS_709;

	struct obs_source_frame out = {0};
	for (int i = 0; i < 3; i++) {
		out.data[i] = f->data[i];
		out.linesize[i] = (uint32_t)f->linesize[i];
	}
	out.width = (uint32_t)f->width;
	out.height = (uint32_t)f->height;
	out.format = fmt;
	out.full_range = full;
	out.timestamp = os_gettime_ns();
	video_format_get_parameters_for_format(cs, full ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL, fmt,
					       out.color_matrix, out.color_range_min, out.color_range_max);

	obs_source_output_video(pc->source, &out);
}

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts)
{
	enum AVPixelFormat want = (enum AVPixelFormat)(intptr_t)ctx->opaque;
	for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
		if (*p == want)
			return *p;
	}
	return avcodec_default_get_format(ctx, fmts);
}

/* Intenta D3D11VA y luego DXVA2. Devuelve el formato de píxel de GPU, o NONE si se usa CPU. */
static enum AVPixelFormat init_hw(AVCodecContext *ctx, const AVCodec *codec)
{
	static const enum AVHWDeviceType types[] = {AV_HWDEVICE_TYPE_D3D11VA, AV_HWDEVICE_TYPE_DXVA2};

	for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
		enum AVPixelFormat fmt = AV_PIX_FMT_NONE;
		const AVCodecHWConfig *cfg;
		for (int j = 0; (cfg = avcodec_get_hw_config(codec, j)) != NULL; j++) {
			if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && cfg->device_type == types[i]) {
				fmt = cfg->pix_fmt;
				break;
			}
		}
		if (fmt == AV_PIX_FMT_NONE)
			continue;

		AVBufferRef *dev = NULL;
		if (av_hwdevice_ctx_create(&dev, types[i], NULL, NULL, 0) < 0)
			continue;

		ctx->hw_device_ctx = dev; /* el contexto se queda con la referencia */
		ctx->opaque = (void *)(intptr_t)fmt;
		ctx->get_format = get_hw_format;
		blog(LOG_INFO, "[phonecam] decodificando por GPU (%s)", av_hwdevice_get_type_name(types[i]));
		return fmt;
	}

	blog(LOG_INFO, "[phonecam] decodificando por CPU");
	return AV_PIX_FMT_NONE;
}

static void run_session(struct phonecam *pc, SOCKET s, bool use_hw)
{
	const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
	AVCodecContext *ctx = codec ? avcodec_alloc_context3(codec) : NULL;
	AVPacket *pkt = av_packet_alloc();
	AVFrame *frame = av_frame_alloc();
	AVFrame *sw = av_frame_alloc();
	uint8_t *buf = NULL;
	int buf_size = 0;

	if (!ctx || !pkt || !frame || !sw)
		goto done;

	/* Un solo hilo + LOW_DELAY: el decoder devuelve cada frame en cuanto lo recibe. */
	ctx->thread_count = 1;
	ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
	enum AVPixelFormat hw_fmt = use_hw ? init_hw(ctx, codec) : AV_PIX_FMT_NONE;
	if (!use_hw)
		blog(LOG_INFO, "[phonecam] decodificando por CPU");

	if (avcodec_open2(ctx, codec, NULL) < 0)
		goto done;

	uint8_t hdr[HEADER_SIZE];
	while (!pc->stop && !pc->reconnect && obs_source_showing(pc->source)) {
		if (!recv_all(pc, s, hdr, HEADER_SIZE))
			break;

		int len = (int)(((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) | ((uint32_t)hdr[2] << 8) |
				(uint32_t)hdr[3]);
		if (len <= 0 || len > MAX_FRAME)
			break;

		int needed = len + AV_INPUT_BUFFER_PADDING_SIZE;
		if (needed > buf_size) {
			uint8_t *nb = realloc(buf, needed);
			if (!nb)
				break;
			buf = nb;
			buf_size = needed;
		}
		if (!recv_all(pc, s, buf, len))
			break;
		memset(buf + len, 0, AV_INPUT_BUFFER_PADDING_SIZE);

		if (hdr[12] & FLAG_STATE) {
			handle_state(pc, buf, len);
			continue;
		}

		pkt->data = buf;
		pkt->size = len;
		pkt->flags = (hdr[12] & FLAG_KEY) ? AV_PKT_FLAG_KEY : 0;
		if (avcodec_send_packet(ctx, pkt) < 0)
			continue;

		while (avcodec_receive_frame(ctx, frame) == 0) {
			if (hw_fmt != AV_PIX_FMT_NONE && frame->format == hw_fmt) {
				/* GPU -> memoria (NV12). Lo pesado, decodificar, ya lo hizo la GPU. */
				if (av_hwframe_transfer_data(sw, frame, 0) == 0) {
					av_frame_copy_props(sw, frame);
					output_frame(pc, sw);
				}
				av_frame_unref(sw);
			} else {
				output_frame(pc, frame);
			}
			av_frame_unref(frame);
		}
	}

done:
	free(buf);
	av_frame_free(&sw);
	av_frame_free(&frame);
	av_packet_free(&pkt);
	avcodec_free_context(&ctx);
}

static DWORD WINAPI worker(LPVOID param)
{
	struct phonecam *pc = param;
	char host[256];
	int port;
	bool use_hw;

	while (!pc->stop) {
		InterlockedExchange(&pc->reconnect, 0);

		/* Si la fuente no se ve en ninguna escena, no conectamos:
		 * el iPhone deja de codificar y el PC no decodifica nada. */
		if (!obs_source_showing(pc->source)) {
			wait_ms(pc, 250);
			continue;
		}

		AcquireSRWLockShared(&pc->lock);
		memcpy(host, pc->host, sizeof(host));
		port = pc->port;
		use_hw = pc->hw_decode;
		ReleaseSRWLockShared(&pc->lock);

		SOCKET s = connect_to(host, port);
		if (s == INVALID_SOCKET) {
			wait_ms(pc, 1000);
			continue;
		}

		/* El saludo tiene que llegar antes que cualquier ajuste. */
		if (send(s, "PCAM1\n", 6, 0) == 6) {
			AcquireSRWLockExclusive(&pc->lock);
			pc->sock = s;
			send_ctl_locked(pc);
			ReleaseSRWLockExclusive(&pc->lock);

			blog(LOG_INFO, "[phonecam] conectado a %s:%d", host, port);
			run_session(pc, s, use_hw);
			blog(LOG_INFO, "[phonecam] desconectado");
		}

		AcquireSRWLockExclusive(&pc->lock);
		pc->sock = INVALID_SOCKET;
		ReleaseSRWLockExclusive(&pc->lock);
		closesocket(s);

		obs_source_output_video(pc->source, NULL);
		wait_ms(pc, 500);
	}
	return 0;
}

/* ------------------------------------------------------------------------- */
/* Fuente de OBS                                                             */

static const char *pc_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "PhoneCam (iPhone)";
}

static void kick_socket(struct phonecam *pc)
{
	AcquireSRWLockExclusive(&pc->lock);
	if (pc->sock != INVALID_SOCKET)
		shutdown(pc->sock, SD_BOTH);
	ReleaseSRWLockExclusive(&pc->lock);
}

static void pc_update(void *data, obs_data_t *settings)
{
	struct phonecam *pc = data;
	const char *host = obs_data_get_string(settings, "host");
	int port = (int)obs_data_get_int(settings, "port");
	bool hw = obs_data_get_bool(settings, "hw_decode");
	char ctl[sizeof(pc->ctl)];
	build_ctl(settings, ctl, sizeof(ctl));

	AcquireSRWLockExclusive(&pc->lock);
	bool reconnect = strcmp(pc->host, host) != 0 || pc->port != port || pc->hw_decode != hw;
	bool ctl_changed = strcmp(pc->ctl, ctl) != 0;
	snprintf(pc->host, sizeof(pc->host), "%s", host);
	pc->port = port;
	pc->hw_decode = hw;
	memcpy(pc->ctl, ctl, sizeof(ctl));
	if (ctl_changed && !reconnect)
		send_ctl_locked(pc);
	ReleaseSRWLockExclusive(&pc->lock);

	if (reconnect) {
		InterlockedExchange(&pc->reconnect, 1);
		kick_socket(pc);
	}
}

static void *pc_create(obs_data_t *settings, obs_source_t *source)
{
	struct phonecam *pc = bzalloc(sizeof(struct phonecam));
	pc->source = source;
	pc->sock = INVALID_SOCKET;
	InitializeSRWLock(&pc->lock);

	obs_source_set_async_unbuffered(source, true);
	pc_update(pc, settings);

	pc->thread = CreateThread(NULL, 0, worker, pc, 0, NULL);
	return pc;
}

static void pc_destroy(void *data)
{
	struct phonecam *pc = data;
	InterlockedExchange(&pc->stop, 1);
	kick_socket(pc);
	if (pc->thread) {
		WaitForSingleObject(pc->thread, INFINITE);
		CloseHandle(pc->thread);
	}
	bfree(pc);
}

static void pc_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "host", "127.0.0.1");
	obs_data_set_default_int(settings, "port", 5000);
	obs_data_set_default_bool(settings, "hw_decode", true);
	obs_data_set_default_string(settings, "mode", "p720_30");
	obs_data_set_default_string(settings, "lens", "wide");
	obs_data_set_default_double(settings, "zoom", 1.0);
	obs_data_set_default_bool(settings, "wb_auto", true);
	obs_data_set_default_int(settings, "temp", 5000);
	obs_data_set_default_bool(settings, "af_auto", true);
	obs_data_set_default_int(settings, "focus", 50);
	obs_data_set_default_double(settings, "ev", 0.0);
	obs_data_set_default_bool(settings, "ae_lock", false);
}

static bool wb_auto_modified(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	obs_property_set_enabled(obs_properties_get(props, "temp"), !obs_data_get_bool(settings, "wb_auto"));
	return true;
}

static bool af_auto_modified(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	obs_property_set_enabled(obs_properties_get(props, "focus"), !obs_data_get_bool(settings, "af_auto"));
	return true;
}

static obs_properties_t *pc_properties(void *unused)
{
	UNUSED_PARAMETER(unused);
	obs_properties_t *props = obs_properties_create();
	obs_property_t *p;

	obs_properties_t *cam = obs_properties_create();
	p = obs_properties_add_list(cam, "mode", "Resolución", OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(p, "720p · 30 fps", "p720_30");
	obs_property_list_add_string(p, "720p · 60 fps", "p720_60");
	obs_property_list_add_string(p, "1080p · 30 fps", "p1080_30");
	obs_property_list_add_string(p, "1080p · 60 fps", "p1080_60");
	obs_property_list_add_string(p, "4K · 30 fps", "p2160_30");

	p = obs_properties_add_list(cam, "lens", "Lente", OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(p, "Normal", "wide");
	obs_property_list_add_string(p, "Tele 2x", "tele");
	obs_property_list_add_string(p, "Frontal", "front");

	obs_properties_add_float_slider(cam, "zoom", "Zoom", 1.0, 8.0, 0.1);

	p = obs_properties_add_bool(cam, "wb_auto", "Balance de blancos automático");
	obs_property_set_modified_callback(p, wb_auto_modified);
	p = obs_properties_add_int_slider(cam, "temp", "Temperatura de color", 2500, 8000, 50);
	obs_property_int_set_suffix(p, " K");

	obs_properties_add_group(props, "camera", "Cámara", OBS_GROUP_NORMAL, cam);

	obs_properties_t *focus = obs_properties_create();
	p = obs_properties_add_bool(focus, "af_auto", "Enfoque automático");
	obs_property_set_modified_callback(p, af_auto_modified);
	p = obs_properties_add_int_slider(focus, "focus", "Distancia (0 = cerca, 100 = lejos)", 0, 100, 1);
	obs_property_set_long_description(p, "La cámara frontal tiene foco fijo: ahí no tiene efecto.");
	obs_properties_add_group(props, "focus_group", "Enfoque", OBS_GROUP_NORMAL, focus);

	obs_properties_t *expo = obs_properties_create();
	p = obs_properties_add_float_slider(expo, "ev", "Compensación (EV)", -3.0, 3.0, 0.1);
	obs_property_set_long_description(p, "Negativo = más oscuro. Si la imagen se quema, bájalo.");
	obs_properties_add_bool(expo, "ae_lock", "Bloquear exposición");
	obs_properties_add_group(props, "exposure_group", "Exposición", OBS_GROUP_NORMAL, expo);

	obs_properties_t *conn = obs_properties_create();
	obs_properties_add_text(conn, "host", "Dirección del iPhone", OBS_TEXT_DEFAULT);
	obs_properties_add_int(conn, "port", "Puerto", 1, 65535, 1);
	obs_properties_add_bool(conn, "hw_decode", "Decodificar con la GPU");
	obs_properties_add_text(conn, "help",
				"Por cable (iproxy): 127.0.0.1\nPor Wi‑Fi: la IP que muestra la app PhoneCam",
				OBS_TEXT_INFO);
	obs_properties_add_group(props, "connection", "Conexión", OBS_GROUP_NORMAL, conn);

	return props;
}

static struct obs_source_info phonecam_source = {
	.id = "phonecam_source",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_DO_NOT_DUPLICATE,
	.icon_type = OBS_ICON_TYPE_CAMERA,
	.get_name = pc_get_name,
	.create = pc_create,
	.destroy = pc_destroy,
	.update = pc_update,
	.get_defaults = pc_defaults,
	.get_properties = pc_properties,
};

bool obs_module_load(void)
{
	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
		return false;
	obs_register_source(&phonecam_source);
	return true;
}

void obs_module_unload(void)
{
	WSACleanup();
}
