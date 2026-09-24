/*
 * PhoneCam: fuente de OBS que recibe el video del iPhone con la menor latencia posible.
 *
 * Protocolo (TCP): al conectar se envía "PCAM1\n"; el iPhone responde con frames
 *   [u32 BE largo][u64 BE pts en µs][u8 flags (1 = keyframe)][H.264 Annex B]
 *
 * A diferencia de la "Fuente multimedia", aquí no hay reloj de reproducción ni búfer:
 * el decoder corre en un solo hilo con LOW_DELAY y cada frame se entrega a OBS
 * apenas se decodifica (fuente async "unbuffered").
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <obs-module.h>
#include <util/platform.h>
#include <libavcodec/avcodec.h>

#include <stdio.h>
#include <string.h>

OBS_DECLARE_MODULE()

MODULE_EXPORT const char *obs_module_description(void)
{
	return "PhoneCam: iPhone como webcam con baja latencia";
}

#define HEADER_SIZE 13
#define MAX_FRAME (16 * 1024 * 1024)

struct phonecam {
	obs_source_t *source;
	HANDLE thread;
	volatile LONG stop;
	volatile LONG reconnect;

	SRWLOCK lock; /* protege host, port y sock */
	char host[256];
	int port;
	SOCKET sock;
};

/* ------------------------------------------------------------------------- */

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

/* ------------------------------------------------------------------------- */

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

static void run_session(struct phonecam *pc, SOCKET s)
{
	const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
	AVCodecContext *ctx = codec ? avcodec_alloc_context3(codec) : NULL;
	AVPacket *pkt = av_packet_alloc();
	AVFrame *frame = av_frame_alloc();
	uint8_t *buf = NULL;
	int buf_size = 0;

	if (!ctx || !pkt || !frame)
		goto done;

	/* Un solo hilo + LOW_DELAY: el decoder devuelve cada frame en cuanto lo recibe. */
	ctx->thread_count = 1;
	ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
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

		pkt->data = buf;
		pkt->size = len;
		pkt->flags = (hdr[12] & 1) ? AV_PKT_FLAG_KEY : 0;
		if (avcodec_send_packet(ctx, pkt) < 0)
			continue;

		while (avcodec_receive_frame(ctx, frame) == 0) {
			output_frame(pc, frame);
			av_frame_unref(frame);
		}
	}

done:
	free(buf);
	av_frame_free(&frame);
	av_packet_free(&pkt);
	avcodec_free_context(&ctx);
}

static DWORD WINAPI worker(LPVOID param)
{
	struct phonecam *pc = param;
	char host[256];
	int port;

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
		ReleaseSRWLockShared(&pc->lock);

		SOCKET s = connect_to(host, port);
		if (s == INVALID_SOCKET) {
			wait_ms(pc, 1000);
			continue;
		}

		AcquireSRWLockExclusive(&pc->lock);
		pc->sock = s;
		ReleaseSRWLockExclusive(&pc->lock);

		if (send(s, "PCAM1\n", 6, 0) == 6) {
			blog(LOG_INFO, "[phonecam] conectado a %s:%d", host, port);
			run_session(pc, s);
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

	AcquireSRWLockExclusive(&pc->lock);
	bool changed = strcmp(pc->host, host) != 0 || pc->port != port;
	snprintf(pc->host, sizeof(pc->host), "%s", host);
	pc->port = port;
	ReleaseSRWLockExclusive(&pc->lock);

	if (changed) {
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
}

static obs_properties_t *pc_properties(void *unused)
{
	UNUSED_PARAMETER(unused);
	obs_properties_t *p = obs_properties_create();
	obs_properties_add_text(p, "host", "Dirección del iPhone", OBS_TEXT_DEFAULT);
	obs_properties_add_int(p, "port", "Puerto", 1, 65535, 1);
	obs_properties_add_text(p, "help",
				"Por cable (iproxy): 127.0.0.1\nPor Wi‑Fi: la IP que muestra la app PhoneCam",
				OBS_TEXT_INFO);
	return p;
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
