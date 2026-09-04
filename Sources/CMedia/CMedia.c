#include "CMedia.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdlib.h>
#include <string.h>

struct MZDecoder {
    AVFormatContext *format;
    AVCodecContext *video, *audio;
    AVBufferRef *device;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *sws;
    SwrContext *swr;
    int vi, ai, receiving, eof, draining;
    CVPixelBufferRef pixel;
    float *samples[2];
    int capacity;
};

static enum AVPixelFormat choose_format(AVCodecContext *ctx, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return formats[0];
}

static AVCodecContext *open_codec(MZDecoder *d, int stream, int hw) {
    AVCodecParameters *par = d->format->streams[stream]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) return NULL;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx || avcodec_parameters_to_context(ctx, par) < 0) { avcodec_free_context(&ctx); return NULL; }
    ctx->thread_count = 2; // Bound codec-internal threads as well as outer workers.
    ctx->max_pixels = 100000000;
    if (hw) {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
        if (av_hwdevice_ctx_create(&d->device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
            ctx->hw_device_ctx = av_buffer_ref(d->device);
            ctx->get_format = choose_format;
        }
    }
    if (avcodec_open2(ctx, codec, NULL) < 0) { avcodec_free_context(&ctx); return NULL; }
    return ctx;
}

MZDecoder *mz_open(const char *path, int audio, int hardware, char *error, int error_size) {
    MZDecoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->vi = d->ai = -1;
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int result = avformat_open_input(&d->format, path, NULL, &options);
    av_dict_free(&options);
    if (result < 0) goto fail;
    if ((result = avformat_find_stream_info(d->format, NULL)) < 0) goto fail;
    d->vi = av_find_best_stream(d->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (d->vi < 0) { result = d->vi; goto fail; }
    d->video = open_codec(d, d->vi, hardware);
    if (!d->video) { result = AVERROR_DECODER_NOT_FOUND; goto fail; }
    if (audio) {
        d->ai = av_find_best_stream(d->format, AVMEDIA_TYPE_AUDIO, -1, d->vi, NULL, 0);
        if (d->ai >= 0) d->audio = open_codec(d, d->ai, 0);
        if (d->audio) {
            AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
            if (swr_alloc_set_opts2(&d->swr, &stereo, AV_SAMPLE_FMT_FLTP, 48000,
                                  &d->audio->ch_layout, d->audio->sample_fmt, d->audio->sample_rate, 0, NULL) < 0 ||
                swr_init(d->swr) < 0) { swr_free(&d->swr); avcodec_free_context(&d->audio); }
        }
        if (!d->audio) d->ai = -1;
    }
    d->packet = av_packet_alloc(); d->frame = av_frame_alloc();
    if (!d->packet || !d->frame) { result = AVERROR(ENOMEM); goto fail; }
    return d;
fail:
    if (error && error_size > 0) av_strerror(result, error, error_size);
    mz_close(d); return NULL;
}

static int export_frame(MZDecoder *d, MZFrame *out, int kind) {
    AVFrame *f = d->frame;
    int stream = kind == 1 ? d->vi : d->ai;
    AVStream *s = d->format->streams[stream];
    int64_t stamp = f->best_effort_timestamp;
    out->seconds = stamp == AV_NOPTS_VALUE ? 0 : stamp * av_q2d(s->time_base);
    if (d->format->start_time != AV_NOPTS_VALUE) out->seconds -= d->format->start_time / (double)AV_TIME_BASE;
    out->seconds = out->seconds < 0 ? 0 : out->seconds;
    out->kind = kind;
    if (kind == 2) {
        int count = swr_get_out_samples(d->swr, f->nb_samples);
        if (count < 0 || count > 96000) return -1;
        if (count > d->capacity) {
            av_freep(&d->samples[0]); av_freep(&d->samples[1]);
            d->samples[0] = av_malloc_array(count, sizeof(float));
            d->samples[1] = av_malloc_array(count, sizeof(float));
            if (!d->samples[0] || !d->samples[1]) return -1;
            d->capacity = count;
        }
        uint8_t *dst[] = {(uint8_t *)d->samples[0], (uint8_t *)d->samples[1]};
        out->samples = swr_convert(d->swr, dst, count, (const uint8_t **)f->extended_data, f->nb_samples);
        out->left = d->samples[0]; out->right = d->samples[1];
        return out->samples >= 0 ? 1 : -1;
    }
    if (f->width <= 0 || f->height <= 0 || (int64_t)f->width * f->height > 100000000) return -1;
    out->hardware = f->format == AV_PIX_FMT_VIDEOTOOLBOX;
    out->full_range = f->color_range == AVCOL_RANGE_JPEG;
    out->bt601 = f->colorspace == AVCOL_SPC_BT470BG || f->colorspace == AVCOL_SPC_SMPTE170M;
    if (out->hardware) {
        d->pixel = CVPixelBufferRetain((CVPixelBufferRef)f->data[3]);
    } else {
        const void *keys[] = {kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey};
        CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *values[] = {kCFBooleanTrue, empty};
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVReturn result = CVPixelBufferCreate(NULL, f->width, f->height, kCVPixelFormatType_32BGRA, attrs, &d->pixel);
        CFRelease(attrs); CFRelease(empty);
        if (result != kCVReturnSuccess) return -1;
        d->sws = sws_getCachedContext(d->sws, f->width, f->height, f->format, f->width, f->height,
                                   AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
        if (!d->sws) return -1;
        int colorspace = out->bt601 ? SWS_CS_ITU601 : SWS_CS_ITU709;
        const int *coefficients = sws_getCoefficients(colorspace);
        sws_setColorspaceDetails(d->sws, coefficients, out->full_range, coefficients, 1, 0, 1<<16, 1<<16);
        CVPixelBufferLockBaseAddress(d->pixel, 0);
        uint8_t *data[] = {CVPixelBufferGetBaseAddress(d->pixel)};
        int stride[] = {(int)CVPixelBufferGetBytesPerRow(d->pixel)};
        sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, data, stride);
        CVPixelBufferUnlockBaseAddress(d->pixel, 0);
    }
    out->pixel = d->pixel;
    return 1;
}

int mz_next(MZDecoder *d, MZFrame *out) {
    memset(out, 0, sizeof(*out));
    if (d->pixel) { CVPixelBufferRelease(d->pixel); d->pixel = NULL; }
    for (;;) {
        if (d->receiving) {
            int kind = d->receiving;
            AVCodecContext *ctx = kind == 1 ? d->video : d->audio;
            int result = avcodec_receive_frame(ctx, d->frame);
            if (result == 0) { int exported = export_frame(d, out, kind); av_frame_unref(d->frame); return exported; }
            d->receiving = 0;
            if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) return -1;
        }
        if (d->eof) {
            if (d->draining == 0) { d->draining = 1; avcodec_send_packet(d->video, NULL); d->receiving = 1; continue; }
            if (d->draining == 1 && d->audio) { d->draining = 2; avcodec_send_packet(d->audio, NULL); d->receiving = 2; continue; }
            return 0;
        }
        int result = av_read_frame(d->format, d->packet);
        if (result == AVERROR_EOF) { d->eof = 1; continue; }
        if (result < 0) return -1;
        int kind = d->packet->stream_index == d->vi ? 1 : (d->packet->stream_index == d->ai ? 2 : 0);
        if (kind) {
            result = avcodec_send_packet(kind == 1 ? d->video : d->audio, d->packet);
            av_packet_unref(d->packet);
            if (result < 0) return -1;
            d->receiving = kind;
        } else av_packet_unref(d->packet);
    }
}

int mz_seek(MZDecoder *d, double seconds) {
    int64_t offset = d->format->start_time == AV_NOPTS_VALUE ? 0 : d->format->start_time;
    if (av_seek_frame(d->format, -1, (int64_t)(seconds * AV_TIME_BASE) + offset, AVSEEK_FLAG_BACKWARD) < 0) return 0;
    avcodec_flush_buffers(d->video);
    if (d->audio) avcodec_flush_buffers(d->audio);
    if (d->swr) { swr_close(d->swr); swr_init(d->swr); }
    d->receiving = d->eof = d->draining = 0;
    return 1;
}
double mz_duration(MZDecoder *d) { return d->format->duration == AV_NOPTS_VALUE ? 0 : d->format->duration/(double)AV_TIME_BASE; }
void mz_close(MZDecoder *d) {
    if (!d) return;
    if (d->pixel) CVPixelBufferRelease(d->pixel);
    sws_freeContext(d->sws); swr_free(&d->swr);
    av_freep(&d->samples[0]); av_freep(&d->samples[1]);
    avcodec_free_context(&d->video); avcodec_free_context(&d->audio);
    av_buffer_unref(&d->device); av_frame_free(&d->frame); av_packet_free(&d->packet);
    avformat_close_input(&d->format); free(d);
}
